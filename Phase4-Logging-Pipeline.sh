#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Introductory-Range"
echo "[*] Adding Phase 4 logging pipeline to $REPO"

cd "$REPO"

echo "[*] Creating Phase 4 directories"
mkdir -p playbooks
mkdir -p roles/{windows-sysmon/{tasks,files},wef-subscription/{tasks,files},winlogbeat-elastic/{tasks,files},linux-logging/{tasks,templates},elastic-stack/tasks}

##############################################
# PHASE 4 PLAYBOOK
##############################################
cat > playbooks/phase4_logging.yml <<'P4'
---
- name: Phase 4 - Windows Sysmon Configuration
  hosts: windows:!domain_controller
  gather_facts: no
  roles:
    - windows-sysmon

- name: Phase 4 - Configure WEF Subscriptions
  hosts: wef_server
  gather_facts: no
  roles:
    - wef-subscription

- name: Phase 4 - Install Winlogbeat on WEF Server
  hosts: wef_server
  gather_facts: no
  roles:
    - winlogbeat-elastic

- name: Phase 4 - Linux Filebeat
  hosts: ubuntu
  become: yes
  roles:
    - linux-logging

- name: Phase 4 - Elastic Stack Setup
  hosts: elastic
  become: yes
  roles:
    - elastic-stack
P4

##############################################
# WINDOWS SYSMON ROLE
##############################################
cat > roles/windows-sysmon/tasks/main.yml <<'SYS'
---
- name: Download Sysmon
  win_get_url:
    url: https://download.sysinternals.com/files/Sysmon.zip
    dest: C:\Sysmon.zip

- name: Extract Sysmon
  win_unzip:
    src: C:\Sysmon.zip
    dest: C:\Sysmon
    delete_archive: yes

- name: Copy Sysmon config
  win_copy:
    src: sysmonconfig.xml
    dest: C:\Sysmon\sysmonconfig.xml

- name: Install Sysmon
  win_shell: |
    C:\Sysmon\Sysmon64.exe -accepteula -i C:\Sysmon\sysmonconfig.xml
  args:
    creates: C:\Windows\System32\Sysmon64.exe
SYS

cat > roles/windows-sysmon/files/sysmonconfig.xml <<'SYSCONF'
<Sysmon schemaversion="4.50">
  <HashAlgorithms>sha256</HashAlgorithms>
  <EventFiltering>
    <ProcessCreate onmatch="exclude" />
  </EventFiltering>
</Sysmon>
SYSCONF

##############################################
# WEF SUBSCRIPTION ROLE
##############################################
cat > roles/wef-subscription/tasks/main.yml <<'WEF'
---
- name: Enable WEF Service
  win_shell: wecutil qc /q

- name: Copy WEF subscription XML
  win_copy:
    src: sysmon-wef.xml
    dest: C:\sysmon-wef.xml

- name: Register or update WEF subscription
  win_shell: |
    wecutil ss "Sysmon-Subscription" /c:C:\sysmon-wef.xml
    if ($LASTEXITCODE -ne 0) { wecutil cs C:\sysmon-wef.xml }
 WEF

cat > roles/wef-subscription/files/sysmon-wef.xml <<'WEFXML'
<Subscription xmlns="http://schemas.microsoft.com/2006/03/windows/events/subscription">
  <SubscriptionId>Sysmon-Subscription</SubscriptionId>
  <SubscriptionType>CollectorInitiated</SubscriptionType>
  <Description>Collects Sysmon Logs from Range Endpoints</Description>
  <Enabled>true</Enabled>
  <Uri>http://schemas.microsoft.com/wbem/wsman/1/windows/EventLog</Uri>
  <ConfigurationMode>Custom</ConfigurationMode>
  <Delivery Mode="Pull">
    <Batching>
      <MaxItems>100</MaxItems>
      <MaxLatencyTime>30000</MaxLatencyTime>
    </Batching>
  </Delivery>
  <CredentialsType>Kerberos</CredentialsType>
  <Query>
    <![CDATA[
    <QueryList>
      <Query Id="0">
        <Select Path="Microsoft-Windows-Sysmon/Operational">*</Select>
      </Query>
    </QueryList>
    ]]>
  </Query>
  <AddressByDomainDN>
    <Member DomainDN="Sorensen.Test" ... />
  </AddressByDomainDN>
</Subscription>
WEFXML

##############################################
# WINLOGBEAT ROLE (FIXED NESTED ZIP & EVENT SOURCE)
##############################################
cat > roles/winlogbeat-elastic/tasks/main.yml <<'WLB'
---
- name: Download Winlogbeat
  win_get_url:
    url: https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-8.12.0-windows-x86_64.zip
    dest: C:\winlogbeat.zip

- name: Extract Archive to Stage Area
  win_unzip:
    src: C:\winlogbeat.zip
    dest: C:\StageWinlogbeat
    delete_archive: yes

- name: Create Program Files Target Destination
  win_file:
    path: C:\Program Files\Winlogbeat
    state: directory

- name: Move and Normalize Binary Assets
  win_shell: |
    Copy-Item -Path "C:\StageWinlogbeat\winlogbeat-8.12.0-windows-x86_64\*" -Destination "C:\Program Files\Winlogbeat" -Recurse -Force
    Remove-Item -Path "C:\StageWinlogbeat" -Recurse -Force
  args:
    creates: C:\Program Files\Winlogbeat\winlogbeat.exe

- name: Copy Winlogbeat config
  win_copy:
    src: winlogbeat.yml
    dest: "C:\\Program Files\\Winlogbeat\\winlogbeat.yml"

- name: Install Winlogbeat service
  win_shell: |
    cd "C:\Program Files\Winlogbeat"
    .\install-service-winlogbeat.ps1
  args:
    creates: C:\Windows\System32\Drivers\winlogbeat.sys

- name: Start Winlogbeat
  win_service:
    name: winlogbeat
    state: started
WLB

cat > roles/winlogbeat-elastic/files/winlogbeat.yml <<'WLBYML'
winlogbeat.event_logs:
  # CHANGED: WEF aggregates remote server logs to ForwardedEvents
  - name: ForwardedEvents

output.elasticsearch:
  hosts: ["10.10.30.20:9200"]
  username: "elastic"
  password: "ElasticP@ssw0rd"
  ssl.verification_mode: "none"

setup.kibana:
  host: "10.10.30.20:5601"
WLBYML

##############################################
# LINUX LOGGING ROLE (ADDED ELASTIC APT SOURCES)
##############################################
cat > roles/linux-logging/tasks/main.yml <<'LINUXLOG'
---
- name: Install Elastic GPG Key
  get_url:
    url: https://artifacts.elastic.co/GPG-KEY-elasticsearch
    dest: /usr/share/keyrings/elastic-keyring.gpg

- name: Add Elastic APT Repository
  apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main"
    state: present
    filename: elastic-8.x

- name: Install Filebeat
  apt:
    name: filebeat
    state: present
    update_cache: yes

- name: Deploy Filebeat config
  template:
    src: filebeat.yml.j2
    dest: /etc/filebeat/filebeat.yml

- name: Enable and start Filebeat
  systemd:
    name: filebeat
    enabled: yes
    state: restarted
LINUXLOG

cat > roles/linux-logging/templates/filebeat.yml.j2 <<'FBT'
filebeat.inputs:
  - type: filestream
    id: syslog
    paths:
      - /var/log/syslog

output.elasticsearch:
  hosts: ["10.10.30.20:9200"]
  username: "elastic"
  password: "ElasticP@ssw0rd"
  ssl.verification_mode: "none"
FBT

##############################################
# ELASTIC STACK ROLE (ADDED REPOS & BIND HOSTS)
##############################################
cat > roles/elastic-stack/tasks/main.yml <<'ELK'
---
- name: Install prerequisites
  apt:
    name:
      - apt-transport-https
      - gpg
      - openjdk-11-jdk
    state: present
    update_cache: yes

- name: Install Elastic GPG Key
  get_url:
    url: https://artifacts.elastic.co/GPG-KEY-elasticsearch
    dest: /usr/share/keyrings/elastic-keyring.gpg

- name: Add Elastic APT Repository
  apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main"
    state: present
    filename: elastic-8.x

- name: Install Elasticsearch
  apt:
    name: elasticsearch
    state: present
    update_cache: yes

- name: Install Kibana
  apt:
    name: kibana
    state: present

- name: Configure Elasticsearch Bind Interface
  lineinfile:
    path: /etc/elasticsearch/elasticsearch.yml
    regexp: '^#?network.host:'
    line: 'network.host: 0.0.0.0'

- name: Disable Initial Elasticsearch Security Bootstrap (For Dev Ranges Only)
  lineinfile:
    path: /etc/elasticsearch/elasticsearch.yml
    regexp: '^xpack.security.enabled:'
    line: 'xpack.security.enabled: false'

- name: Configure Kibana Network Host
  lineinfile:
    path: /etc/kibana/kibana.yml
    regexp: '^#?server.host:'
    line: 'server.host: "0.0.0.0"'

- name: Enable and start Elasticsearch
  systemd:
    name: elasticsearch
    enabled: yes
    state: started

- name: Enable and start Kibana
  systemd:
    name: kibana
    enabled: yes
    state: started
ELK

echo
echo "===================================================="
echo "Phase 4 logging files successfully integrated into $REPO"
echo "Run:"
echo "  ansible-playbook -i inventory/hosts.yml playbooks/phase4_logging.yml"
echo "===================================================="
