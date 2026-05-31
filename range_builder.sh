#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Introductory-Range"
echo "[*] Creating repo at $REPO"
rm -rf "$REPO"
mkdir -p "$REPO"
cd "$REPO"

echo "[*] Installing prerequisites"
sudo apt update
sudo apt install -y ansible python3-pip unzip
pip3 install -q pywinrm

echo "[*] Creating directory structure"
mkdir -p inventory/group_vars playbooks bootstrap roles
mkdir -p roles/{ad-structure/{tasks,files},domain-controller/tasks,certificate-authority/tasks,windows-domain-join/tasks,windows-bootstrap/{tasks,files}}

##############################################
# INVENTORY
##############################################
cat > inventory/hosts.yml <<'INVENTORY'
all:
  children:
    windows:
      vars:
        ansible_user: Administrator
        ansible_connection: winrm
        ansible_winrm_transport: basic
        ansible_port: 5985
        ansible_winrm_server_cert_validation: ignore
      
      hosts:
        domain_controller:
          ansible_host: 10.10.0.10
          ansible_password: 'wv)oO6uTQ2x*3lrgNt4$R7taJl1sFtZL'
          hostname: dc01

        win-workstation1:
          ansible_host: 10.10.20.10
          ansible_password: 'cj7Z!zki!)Y!X7!=koF5xvqpv%Usn1Ld'
          hostname: off-wks01

        win-workstation2:
          ansible_host: 10.10.20.20
          ansible_password: '&ZtDkz%b&SOjTeJ7UI@kw*iH*dnvqJrW'
          hostname: off-wks02

        certificate_authority:
          ansible_host: 10.10.0.20
          ansible_password: 'D*Ngl98O8=Hm1VO0xp@X=bH2Q!=TU9xf'
          hostname: ca01

        file_server:
          ansible_host: 10.10.10.10
          ansible_password: 'x=S;n)OCgUM3l?nFUl=b3==.avBwEIHK'
          hostname: fs01

        wef_server:
          ansible_host: 10.10.30.10
          ansible_password: '6@x4y.n$DtrSYW08wun8TEXaLJGknlNp'
          hostname: wef01

    windows_bootstrap:
      hosts:
        domain_controller:
        win-workstation1:
        win-workstation2:
        certificate_authority:
        file_server:
        wef_server:
      vars:
        ansible_connection: smb
        ansible_user: Administrator
        ansible_password: "{{ hostvars[inventory_hostname].ansible_password }}"

    ubuntu:
      vars:
        ansible_user: ubuntu
        ansible_ssh_private_key_file: ssh_private_key.pem
        ansible_python_interpreter: /usr/bin/python3
      
      hosts:
        lin-workstation1:
          ansible_host: 10.10.20.30
          hostname: off-wks03

        ubuntu-ansible:
          ansible_host: 10.10.40.10
          hostname: ansible-temp

        elastic:
          ansible_host: 10.10.30.20
          hostname: elk01
INVENTORY

##############################################
# GROUP VARS
##############################################
cat > inventory/group_vars/all.yml <<'GV'
domain_name: Sorensen.Test
netbios_name: SORENSEN

domain_admin: "SORENSEN\\m.magdelena"
domain_admin_password: "10Ek!d0S[1qX*d[=o^k&"

dsrm_password: "}e5K@Z98rE_W"

ca_config: "CA01.Sorensen.Test\\SORENSEN-CA"
cert_template: "Machine"
GV

##############################################
# BOOTSTRAP SCRIPT (PHASE 1 WINDOWS)
##############################################
cat > bootstrap/bootstrap_pre_domain.ps1 <<'BOOT'
$pass = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force
New-LocalUser -Name "ansible" -Password $pass -FullName "Ansible User" -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "ansible" -ErrorAction SilentlyContinue

winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true";CredSSP="true"}'

New-NetFirewallRule -Name "WINRM-HTTP" -DisplayName "WINRM-HTTP" -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound -ErrorAction SilentlyContinue
BOOT

##############################################
# PLAYBOOKS
##############################################
cat > playbooks/phase1_windows_bootstrap.yml <<'P1W'
---
- name: Phase 1 - Windows bootstrap via SMB
  hosts: windows_bootstrap
  gather_facts: no

  tasks:
    - name: Copy bootstrap_pre_domain.ps1
      ansible.windows.win_copy:
        src: bootstrap/bootstrap_pre_domain.ps1
        dest: C:\bootstrap_pre_domain.ps1

    - name: Run bootstrap_pre_domain.ps1
      ansible.windows.win_shell: powershell.exe -ExecutionPolicy Bypass -File C:\bootstrap_pre_domain.ps1
P1W

cat > playbooks/phase1_linux_bootstrap.yml <<'P1L'
---
- name: Phase 1 - Linux bootstrap
  hosts: ubuntu
  become: yes
  gather_facts: yes

  tasks:
    - name: Ensure ansible user exists
      user:
        name: ansible
        groups: sudo
        append: yes
        state: present
P1L

cat > playbooks/phase2_domain_and_ca.yml <<'P2'
---
- hosts: domain_controller
  gather_facts: no
  roles:
    - domain-controller

- hosts: certificate_authority
  gather_facts: no
  roles:
    - certificate-authority

- hosts: domain_controller
  gather_facts: no
  roles:
    - ad-structure
P2

cat > playbooks/phase3_post_domain.yml <<'P3'
---
- hosts: windows:!domain_controller
  gather_facts: no
  roles:
    - windows-domain-join
    - windows-bootstrap
P3

cat > playbooks/site.yml <<'SITE'
---
- import_playbook: phase2_domain_and_ca.yml
- import_playbook: phase3_post_domain.yml
SITE

##############################################
# DOMAIN CONTROLLER ROLE
##############################################
cat > roles/domain-controller/tasks/main.yml <<'DC'
---
- name: Promote to domain controller
  win_domain:
    dns_domain_name: "{{ domain_name }}"
    safe_mode_password: "{{ dsrm_password }}"
    domain_admin_user: "{{ domain_admin }}"
    domain_admin_password: "{{ domain_admin_password }}"
    state: domain_controller
  register: dc_promo

- name: Reboot after promotion
  win_reboot:
  when: dc_promo.reboot_required

- name: Wait for AD DS to be ready
  win_shell: |
    while (-not (Get-Service NTDS -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5 }
    while ((Get-Service NTDS).Status -ne 'Running') { Start-Sleep -Seconds 5 }
  retries: 30
  delay: 5
  register: ad_ready
  until: ad_ready.rc == 0

- name: Ensure DC uses itself for DNS
  win_dns_client:
    adapter_names: "*"
    dns_servers:
      - 127.0.0.1
DC

##############################################
# CERTIFICATE AUTHORITY ROLE
##############################################
cat > roles/certificate-authority/tasks/main.yml <<'CA'
---
- name: Point CA DNS to DC
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Install ADCS
  win_feature:
    name: ADCS-Cert-Authority
    state: present
    include_management_tools: yes

- name: Configure Enterprise Root CA
  win_shell: Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -Force
  args:
    creates: C:\Windows\System32\CertSrv
CA

##############################################
# AD STRUCTURE ROLE
##############################################
cat > roles/ad-structure/tasks/main.yml <<'ADMAIN'
---
- import_tasks: ou_groups.yml
- import_tasks: users.yml
ADMAIN

cat > roles/ad-structure/tasks/ou_groups.yml <<'OUG'
---
- name: Create enterprise admin user
  microsoft.ad.user:
    name: m.magdelena
    firstname: Maria
    surname: Magdelena
    password: '10Ek!d0S[1qX*d[=o^k&'
    password_never_expires: yes
    groups:
      add:
        - Enterprise Admins
        - Domain Admins
        - Schema Admins

- name: Create base groups OU
  microsoft.ad.ou:
    name: Base Groups
    path: "DC=Sorensen,DC=Test"
    state: present

- name: Create base groups
  microsoft.ad.group:
    name: "{{ item }}"
    path: "OU=Base Groups,DC=Sorensen,DC=Test"
    scope: global
  loop:
    - Workstations
    - Servers

- name: Create Departments OU
  microsoft.ad.ou:
    name: Departments
    path: "DC=Sorensen,DC=Test"
    state: present

- name: Create OU structure
  microsoft.ad.ou:
    name: "{{ item.name }}"
    path: "{{ item.path }},DC=Sorensen,DC=Test"
    state: present
  loop:
    - { name: 'Finance', path: 'OU=Departments' }
    - { name: 'IT', path: 'OU=Departments' }
    - { name: 'Management', path: 'OU=Departments' }
    - { name: 'Human Resources', path: 'OU=Departments' }
    - { name: 'Operations', path: 'OU=Departments' }
    - { name: 'Computers', path: 'OU=Finance,OU=Departments' }
    - { name: 'Computers', path: 'OU=IT,OU=Departments' }
    - { name: 'Computers', path: 'OU=Management,OU=Departments' }
    - { name: 'Computers', path: 'OU=Human Resources,OU=Departments' }
    - { name: 'Computers', path: 'OU=Operations,OU=Departments' }
    - { name: 'Servers', path: 'OU=Computers,OU=Finance,OU=Departments' }
    - { name: 'Servers', path: 'OU=Computers,OU=IT,OU=Departments' }
    - { name: 'Servers', path: 'OU=Computers,OU=Management,OU=Departments' }
    - { name: 'Servers', path: 'OU=Computers,OU=Human Resources,OU=Departments' }
    - { name: 'Servers', path: 'OU=Computers,OU=Operations,OU=Departments' }
    - { name: 'Workstations', path: 'OU=Computers,OU=Finance,OU=Departments' }
    - { name: 'Workstations', path: 'OU=Computers,OU=IT,OU=Departments' }
    - { name: 'Workstations', path: 'OU=Computers,OU=Management,OU=Departments' }
    - { name: 'Workstations', path: 'OU=Computers,OU=Human Resources,OU=Departments' }
    - { name: 'Workstations', path: 'OU=Computers,OU=Operations,OU=Departments' }
    - { name: 'Users', path: 'OU=Finance,OU=Departments' }
    - { name: 'Users', path: 'OU=IT,OU=Departments' }
    - { name: 'Users', path: 'OU=Management,OU=Departments' }
    - { name: 'Users', path: 'OU=Human Resources,OU=Departments' }
    - { name: 'Users', path: 'OU=Operations,OU=Departments' }
    - { name: 'Accounts', path: 'OU=Users,OU=Finance,OU=Departments' }
    - { name: 'Accounts', path: 'OU=Users,OU=IT,OU=Departments' }
    - { name: 'Accounts', path: 'OU=Users,OU=Management,OU=Departments' }
    - { name: 'Accounts', path: 'OU=Users,OU=Human Resources,OU=Departments' }
    - { name: 'Accounts', path: 'OU=Users,OU=Operations,OU=Departments' }
    - { name: 'Groups', path: 'OU=Users,OU=Finance,OU=Departments' }
    - { name: 'Groups', path: 'OU=Users,OU=IT,OU=Departments' }
    - { name: 'Groups', path: 'OU=Users,OU=Management,OU=Departments' }
    - { name: 'Groups', path: 'OU=Users,OU=Human Resources,OU=Departments' }
    - { name: 'Groups', path: 'OU=Users,OU=Operations,OU=Departments' }
    - { name: 'Services', path: 'OU=Users,OU=Finance,OU=Departments' }
    - { name: 'Services', path: 'OU=Users,OU=IT,OU=Departments' }
    - { name: 'Services', path: 'OU=Users,OU=Management,OU=Departments' }
    - { name: 'Services', path: 'OU=Users,OU=Human Resources,OU=Departments' }
    - { name: 'Services', path: 'OU=Users,OU=Operations,OU=Departments' }

- name: Create groups
  microsoft.ad.group:
    name: "{{ item.name }}"
    path: "{{ item.path }},OU=Departments,DC=Sorensen,DC=Test"
    scope: global
  loop:
    - { name: 'HR Staff', path: 'OU=Groups,OU=Users,OU=Human Resources' }
    - { name: 'Finance Staff', path: 'OU=Groups,OU=Users,OU=Finance' }
    - { name: 'Operations Staff', path: 'OU=Groups,OU=Users,OU=Operations' }
    - { name: 'Mgmnt Staff', path: 'OU=Groups,OU=Users,OU=Management' }
    - { name: 'IT Staff', path: 'OU=Groups,OU=Users,OU=IT' }
OUG

cat > roles/ad-structure/tasks/users.yml <<'USERTASK'
---
- name: Load user data
  include_vars:
    file: ../ad-structure/files/domain_users.yml
    name: users_data

- name: Flatten users
  set_fact:
    flat_users: >-
      {% set users = [] %}
      {% for dept in users_data.users %}
        {% for u in dept.user_info %}
          {% set _ = users.append({'path': dept.ou_path, 'username': u.username, 'first': u.first_name, 'surname': u.surname, 'password': u.password, 'groups': u.domain_groups}) %}
        {% endfor %}
      {% endfor %}
      {{ users }}

- name: Create users
  microsoft.ad.user:
    name: "{{ item.username }}"
    firstname: "{{ item.first }}"
    surname: "{{ item.surname }}"
    password: "{{ item.password }}"
    path: "{{ item.path }},OU=Departments,DC=Sorensen,DC=Test"
    email: "{{ item.username }}@sorensen.test"
    groups:
      add: "{{ item.groups }}"
    password_never_expires: yes
  loop: "{{ flat_users }}"
  loop_control:
    label: "{{ item.username }}"
USERTASK

# POPULATED & SANITIZED: Completed the missing file content blocks
cat > roles/ad-structure/files/domain_users.yml <<'USERFILE'
---
users:
  - ou_path: "OU=Accounts,OU=Users,OU=Human Resources"
    user_info:
      - { first_name: 'Avery', surname: 'Blake', username: 'a.blake', password: '7=ABO{j17$=D', domain_groups: ['HR Staff'] }
      - { first_name: 'Serenity', surname: 'Daugherty', username: 's.daugherty', password: 'd<Gw(OZW943K', domain_groups: ['HR Staff'] }
      - { first_name: 'Ali', surname: 'Chang', username: 'a.chang', password: 'I,!:p9Q7;4od', domain_groups: ['HR Staff'] }
      - { first_name: 'Amina', surname: 'Allison', username: 'a.allison', password: 'rg_vBH0:44m*', domain_groups: ['HR Staff'] }
      - { first_name: 'Kieran', surname: 'Mccormick', username: 'k.mccormick', password: '7q^q~p2/8o-E', domain_groups: ['HR Staff'] }

  - ou_path: "OU=Accounts,OU=Users,OU=IT"
    user_info:
      - { first_name: 'Eden', surname: 'Castaneda', username: 'e.castaneda', password: 'x61492D&m0]~', domain_groups: ['IT Staff'] }
      - { first_name: 'Alejandro', surname: 'Vaughan', username: 'a.vaughan', password: 'u+2{77{A"*v6', domain_groups: ['IT Staff'] }
      - { first_name: 'Lukas', surname: 'Velasquez', username: 'l.velasquez', password: '=W9r@h497Cq(', domain_groups: ['IT Staff'] }
      - { first_name: 'Alissa', surname: 'Quinn', username: 'a.quinn', password: 'FwS.o85}Z9!8', domain_groups: ['IT Staff'] }
      - { first_name: 'Jeffery', surname: 'Mcdowell', username: 'j.mcdowell', password: '(e9h,27&GS7{', domain_groups: ['IT Staff'] }

  - ou_path: "OU=Accounts,OU=Users,OU=Finance"
    user_info:
      - { first_name: 'Mikaela', surname: 'Fleming', username: 'm.fleming', password: '._>70D9`cs4I', domain_groups: ['Finance Staff'] }
      - { first_name: 'Kaitlyn', surname: 'Mccall', username: 'k.mccall', password: '76yY$Wu2MC8b', domain_groups: ['Finance Staff'] }
      - { first_name: 'Kieran', surname: 'Lloyd', username: 'k.lloyd', password: "38'*o#OJ/T/2", domain_groups: ['Finance Staff'] }
      - { first_name: 'Tom', surname: 'Pacheco', username: 't.pacheco', password: "a/g1-9'68IXM", domain_groups: ['Finance Staff'] }
      - { first_name: 'Timothy', surname: 'Leach', username: 't.leach', password: '4Ab[a2:6fC`+', domain_groups: ['Finance Staff'] }

  - ou_path: "OU=Accounts,OU=Users,OU=Operations"
    user_info:
      - { first_name: 'Mateo', surname: 'Mccarty', username: 'm.mccarty', password: '4]5UDu_2ns:F', domain_groups: ['Operations Staff'] }
      - { first_name: 'Bryan', surname: 'Mason', username: 'b.mason', password: 'n5cfl193R1A1', domain_groups: ['Operations Staff'] }
      - { first_name: 'Leonardo', surname: 'Brady', username: 'l.brady', password: '160ZgK5nsr87', domain_groups: ['Operations Staff'] }
      - { first_name: 'Reagan', surname: 'Velazquez', username: 'r.velazquez', password: 'oEY3YhP8dph5', domain_groups: ['Operations Staff'] }
      - { first_name: 'Kaela', surname: 'Tanya', username: 'k.tanya', password: 'DMHtZ8h8h1xw', domain_groups: ['Operations Staff'] }

  - ou_path: "OU=Accounts,OU=Users,OU=Management"
    user_info:
      - { first_name: 'Milton', surname: 'Rivera', username: 'm.rivera', password: 'hjSKVj0793w2', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Irvin', surname: 'Holland', username: 'i.holland', password: 'j0YY728sTw8A', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Myla', surname: 'Sosa', username: 'm.sosa', password: 'UxzS7Ir60mJO', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Kamari', surname: 'Johnson', username: 'k.johnson', password: '6lzz0TCC3CgH', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Lacey', surname: 'Potter', username: 'l.potter', password: 't61w42Gf5snK', domain_groups: ['Mgmnt Staff'] }
USERFILE

##############################################
# WINDOWS DOMAIN JOIN ROLE
##############################################
cat > roles/windows-domain-join/tasks/main.yml <<'JOIN'
---
- name: Point DNS to Domain Controller
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Join Sorensen.Test domain
  win_domain_membership:
    dns_domain_name: "{{ domain_name }}"
    domain_admin_user: "{{ domain_admin }}"
    domain_admin_password: "{{ domain_admin_password }}"
    state: domain
  register: domain_join

- name: Reboot after domain join
  win_reboot:
  when: domain_join.reboot_required
JOIN

##############################################
# POST-DOMAIN BOOTSTRAP ROLE
##############################################
cat > roles/windows-bootstrap/tasks/main.yml <<'WB'
---
- name: Copy post-domain bootstrap script
  win_copy:
    src: bootstrap-win-post-domain.ps1
    dest: C:\bootstrap-win-post-domain.ps1

- name: Run post-domain bootstrap script
  win_shell: powershell.exe -ExecutionPolicy Bypass -File C:\bootstrap-win-post-domain.ps1 -CA "{{ ca_config }}" -Template "{{ cert_template }}"
  register: post_bootstrap

- name: Reset connection
  meta: reset_connection
WB

cat > roles/windows-bootstrap/files/bootstrap-win-post-domain.ps1 <<'WBPS'
param(
    [string]$CA,
    [string]$Template = "Machine"
)

$inf = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "CN=$env:COMPUTERNAME"
KeyLength = 2048
Exportable = TRUE
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
UseExistingKeySet = FALSE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
RequestType = PKCS10
KeyUsage = 0xa0

[RequestAttributes]
CertificateTemplate = $Template
"@

$infPath = "C:\cert.inf"
$reqPath = "C:\cert.req"
$cerPath = "C:\cert.cer"

$inf | Out-File $infPath -Encoding ascii
certreq -new $infPath $reqPath
certreq -submit -config $CA $reqPath $cerPath
certreq -accept $cerPath

$thumb = (Get-ChildItem Cert:\LocalMachine\My | Sort-Object NotAfter -Descending | Select-Object -First 1).Thumbprint
winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`"; CertificateThumbprint=`"$thumb`"}"

winrm delete winrm/config/Listener?Address=*+Transport=HTTP
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Basic="false"}'
WBPS

##############################################
# INSTALL REQUIRED COLLECTIONS
##############################################
echo "[*] Installing Ansible collections"
ansible-galaxy collection install ansible.windows community.windows microsoft.ad

echo
echo "===================================================="
echo "Repo created successfully at $REPO"
echo "===================================================="
