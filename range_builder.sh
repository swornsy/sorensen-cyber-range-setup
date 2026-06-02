#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Introductory-Range"
echo "[*] Creating repo at $REPO"
rm -rf "$REPO"
mkdir -p "$REPO"
cd "$REPO"

echo "[*] Installing prerequisites"
sudo apt update
sudo apt install -y python3-pip unzip
# Fix for the galaxy dependency resolution bug: Clean install matched packages
sudo apt remove --purge -y ansible ansible-core || true
sudo apt autoremove -y
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt update
sudo apt install -y ansible net-tools
pip3 install -q pywinrm
rm -rf ~/.ansible/galaxy_cache

echo "[*] Creating directory structure"
mkdir -p inventory/group_vars playbooks/bootstrap playbooks/roles
mkdir -p playbooks/roles/{ad-structure/{tasks,files},domain-controller/tasks,certificate-authority/tasks,windows-domain-join/tasks,windows-bootstrap/{tasks,files}}

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
          ansible_password: '&l.)D&ah?cm*c6wTXI2d6Op;?p$k;Hj9'
          hostname: dc01

        win-workstation1:
          ansible_host: 10.10.20.10
          ansible_password: 'afQ5=aLS.FN*k7fuTn-hdrTdI(vqT-Z.'
          hostname: off-wks01

        win-workstation2:
          ansible_host: 10.10.20.20
          ansible_password: 'pQ)CkMhs$vv2%pN@bYT4l%3-O?McDn=F'
          hostname: off-wks02

        certificate_authority:
          ansible_host: 10.10.0.20
          ansible_password: 'Tbza9wT@c)81HYAYYgEbVaLI2u3S2sdb'
          hostname: ca01

        file_server:
          ansible_host: 10.10.10.10
          ansible_password: 'K&9*)Y9?1ZJ8r8N4ABRRPR7h=fyF%jY8'
          hostname: fs01

        wef_server:
          ansible_host: 10.10.30.10
          ansible_password: 'XrjAZ=T;Xy!%XQw26Ab*6cxL&oc!U;Uq'
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
        ansible_connection: winrm
        ansible_user: Administrator
        ansible_password: "{{ hostvars[inventory_hostname].ansible_password }}"
        ansible_port: 5985
        ansible_winrm_server_cert_validation: ignore

    ubuntu:
      vars:
        ansible_user: ubuntu
        ansible_ssh_private_key_file: "/home/ubuntu/sorensen_test.pem"
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

cert_template: "Machine"
GV

##############################################
# BOOTSTRAP SCRIPT (PHASE 1 WINDOWS)
##############################################
cat > playbooks/bootstrap/bootstrap_pre_domain.ps1 <<'BOOT'
# 1. Stand up a dedicated local administrator for Ansible orchestration tasks
$pass = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force
New-LocalUser -Name "ansible" -Password $pass -FullName "Ansible User" -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "ansible" -ErrorAction SilentlyContinue

# 2. DYNAMIC ROLE IDENTIFICATION (Your integrated check converted to a clean Boolean)
$IsDC = [bool](Get-NetIPAddress | Where-Object { $_.IPAddress -eq "10.10.0.10" })

if ($IsDC) {
    Write-Output "[*] Identified as Domain Controller via Local IP Verification"
    # Ensure DNS points cleanly to localhost loopback for initial AD DS directory configuration
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ("127.0.0.1") -ErrorAction SilentlyContinue
} else {
    Write-Output "[*] Identified as Member Workstation/CA via Local IP Verification"
    # Route all non-DC endpoints straight to the primary domain controller for name resolution
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ("10.10.0.10") -ErrorAction SilentlyContinue
}

# 3. Recycle and clear old WinRM listeners in-memory to purge ghost configurations safely
Stop-Service WinRM -ErrorAction SilentlyContinue
winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null

# 4. Bind the fresh, pristine base HTTP port 5985 listener channel
winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true";CredSSP="true"}'
Start-Service WinRM -ErrorAction SilentlyContinue

# 5. Open strict inbound host firewall filters across all profiles
New-NetFirewallRule -Name "WINRM-HTTP" -DisplayName "WINRM-HTTP" -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WINRM-HTTPS" -DisplayName "WINRM-HTTPS" -Protocol TCP -LocalPort 5986 -Action Allow -Direction Inbound -Profile Any -ErrorAction SilentlyContinue
BOOT

##############################################
# PLAYBOOKS
##############################################
cat > playbooks/phase1_windows_bootstrap.yml <<'P1W'
---
- name: Phase 1 - Windows bootstrap via winrm
  hosts: windows_bootstrap
  gather_facts: no

  tasks:
    - name: Copy bootstrap_pre_domain.ps1
      ansible.windows.win_copy:
        src: "{{ playbook_dir }}/bootstrap/bootstrap_pre_domain.ps1"
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

- hosts: domain_controller
  gather_facts: no
  roles:
    - ad-structure

- hosts: certificate_authority
  gather_facts: no
  roles:
    - windows-domain-join

- hosts: certificate_authority
  gather_facts: no
  vars:
    ansible_become: yes
    ansible_become_method: runas
    ansible_become_user: "{{ domain_admin }}"
    ansible_become_password: "{{ domain_admin_password }}"
  roles:
    - certificate-authority
P2

cat > playbooks/phase3_post_domain.yml <<'P3'
---
- hosts: windows:!domain_controller:!certificate_authority
  gather_facts: no
  roles:
    - windows-domain-join

- hosts: windows
  gather_facts: no
  roles:
    - windows-bootstrap
P3

cat > playbooks/site.yml <<'SITE'
---
- import_playbook: phase1_windows_bootstrap.yml
- import_playbook: phase1_linux_bootstrap.yml
- import_playbook: phase2_domain_and_ca.yml
- import_playbook: phase3_post_domain.yml
SITE

##############################################
# DOMAIN CONTROLLER ROLE
##############################################
cat > playbooks/roles/domain-controller/tasks/main.yml <<'DC'
---
- name: Promote to domain controller
  microsoft.ad.domain:
    dns_domain_name: "{{ domain_name }}"
    safe_mode_password: "{{ dsrm_password }}"
    domain_netbios_name: "{{ netbios_name }}"
    install_dns: yes
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
cat > playbooks/roles/certificate-authority/tasks/main.yml <<'CA'
---
- name: Point CA DNS to DC
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Wait for Active Directory Domain space verification
  win_shell: |
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    if ($domain) { exit 0 } else { exit 1 }
  retries: 15
  delay: 10
  register: ad_net_check
  until: ad_net_check.rc == 0

- name: Install ADCS
  win_feature:
    name: ADCS-Cert-Authority
    state: present
    include_management_tools: yes

- name: Configure Enterprise Root CA
  win_shell: Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -Force
  args:
    creates: C:\Windows\System32\CertSrv

- name: Grant Domain Computers enrollment access to the Machine template
  win_shell: |
    certutil -setreg policy\Machine\EnrollmentRights "+Domain Computers:Enroll"
    Restart-Service CertSvc
CA

##############################################
# AD STRUCTURE ROLE
##############################################
cat > playbooks/roles/ad-structure/tasks/main.yml <<'ADMAIN'
---
- import_tasks: ou_groups.yml
- import_tasks: users.yml
ADMAIN

cat > playbooks/roles/ad-structure/tasks/ou_groups.yml <<'OUG'
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

cat > playbooks/roles/ad-structure/tasks/users.yml <<'USERTASK'
---
- name: Load user data
  include_vars:
    file: ../ad-structure/files/domain_users.yml
    name: users_data

- name: Flatten users structure cleanly
  set_fact:
    flat_users: "{{ users_data.users | map(attribute='user_info') | flatten }}"

- name: Create users
  microsoft.ad.user:
    name: "{{ item.username }}"
    firstname: "{{ item.first_name }}"
    surname: "{{ item.surname }}"
    password: "{{ item.password }}"
    path: "{{ users_data.users | selectattr('user_info', 'contains', item) | map(attribute='ou_path') | first }},OU=Departments,DC=Sorensen,DC=Test"
    email: "{{ item.username }}@sorensen.test"
    groups:
      add: "{{ item.domain_groups }}"
    password_never_expires: yes
  loop: "{{ flat_users }}"
  loop_control:
    label: "{{ item.username }}"
USERTASK

cat > playbooks/roles/ad-structure/files/domain_users.yml <<'USERFILE'
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
cat > playbooks/roles/windows-domain-join/tasks/main.yml <<'JOIN'
---
- name: Point DNS to Domain Controller
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Join Sorensen.Test domain
  microsoft.ad.membership:
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
# POST-DOMAIN BOOTSTRAP ROLE (INTEGRATED PHASE 3)
##############################################
cat > playbooks/roles/windows-bootstrap/tasks/main.yml <<'WB'
---
- name: Upload Phase 3 Builder Script
  ansible.windows.win_copy:
    src: Range-Phase3-Builder.ps1
    dest: C:\Range-Phase3-Builder.ps1

- name: Ensure WinRM HTTP is configured and firewall open
  ansible.windows.win_shell: |
    winrm quickconfig -q
    winrm set winrm/config/service '@{AllowUnencrypted="false"}'
    winrm set winrm/config/service/auth '@{Basic="false";Kerberos="true";Negotiate="true"}'
    if (-not (Get-NetFirewallRule -DisplayName "WinRM_HTTP_5985" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName "WinRM_HTTP_5985" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 | Out-Null
    }
  args:
    executable: powershell.exe

- name: Execute Phase 3 Builder — DC role
  ansible.windows.win_shell: |
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 `
      -Role DC `
      -DomainFqdn "{{ domain_name }}" `
      -CaHostname "ca01" `
      -TemplateName "{{ cert_template }}"
  when: inventory_hostname == 'domain_controller'

- name: Execute Phase 3 Builder — CA role
  ansible.windows.win_shell: |
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 `
      -Role CA `
      -DomainFqdn "{{ domain_name }}" `
      -CaHostname "ca01" `
      -TemplateName "{{ cert_template }}"
  when: inventory_hostname == 'certificate_authority'

- name: Execute Phase 3 Builder — Member role (Auto-Enroll & Create HTTPS Listener)
  ansible.windows.win_shell: |
    # 1. Run baseline member configuration parameters (Firewalls, CredSSP)
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 -Role Member -DomainFqdn "{{ domain_name }}" -CaHostname "ca01" -TemplateName "{{ cert_template }}"
    
    # 2. Issue local Active Directory enrollment directives natively under machine token
    gpupdate.exe /force
    certutil.exe -pulse
    Get-Certificate -Template "{{ cert_template }}" -Url "LDAP:" -CertStoreLocation "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue
    
    # 3. Provision the companion HTTPS listener alongside the baseline transport
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Enhanced Key Usage" -and $_.Format(0) -match "Server Authentication" }
    } | Sort-Object NotBefore -Descending | Select-Object -First 1
    
    if ($cert) {
        winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME.{{ domain_name }}`"; CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    } else {
        throw "Failed to provision enterprise domain certificate securely"
    }
  when: inventory_hostname != 'domain_controller' and inventory_hostname != 'certificate_authority'

- name: Pivot connection variables to HTTPS
  set_fact:
    ansible_port: 5986
    ansible_winrm_transport: credssp
    ansible_winrm_server_cert_validation: ignore

- name: Reset connection to use HTTPS listener
  meta: reset_connection

- name: Remove HTTP listener after HTTPS is live
  ansible.windows.win_shell: |
    winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
  args:
    executable: powershell.exe

- name: Core connection verification
  win_ping:
WB

# Inject your custom helper script safely into the files directory
cat > playbooks/roles/windows-bootstrap/files/Range-Phase3-Builder.ps1 <<'PHASE3_SCRIPT'
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('CA','Member','DC')]
    [string]$Role,

    [Parameter(Mandatory=$true)]
    [string]$DomainFqdn,

    [Parameter(Mandatory=$true)]
    [string]$CaHostname,

    [Parameter(Mandatory=$true)]
    [string]$TemplateName
)

function Write-Status {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts][$Level] $Message"
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 10,
        [string]$Description = "operation"
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Write-Status "Attempt $i/$MaxAttempts: $Description"
            $result = & $ScriptBlock
            return $result
        }
        catch {
            Write-Status "Failed attempt $i: $($_.Exception.Message)" "WARN"
            if ($i -lt $MaxAttempts) {
                Start-Sleep -Seconds $DelaySeconds
            } else {
                throw "Exceeded max attempts for $Description"
            }
        }
    }
}

function Test-CAReadiness {
    param(
        [string]$CaHostname,
        [string]$TemplateName
    )

    Write-Status "Checking CA service on $CaHostname"
    Invoke-WithRetry -Description "Ping CA RPC" -ScriptBlock {
        certutil.exe -ping $CaHostname | Out-Null
    }

    Write-Status "Checking template '$TemplateName' is published on CA"
    Invoke-WithRetry -Description "Check template presence" -ScriptBlock {
        $templates = certutil.exe -config "$CaHostname\CA" -template | Out-String
        if ($templates -notmatch [regex]::Escape($TemplateName)) {
            throw "Template '$TemplateName' not found yet"
        }
    }
    Write-Status "CA '$CaHostname' and template '$TemplateName' appear ready"
}

function Ensure-CATemplatePermissions {
    param(
        [string]$TemplateName
    )

    Write-Status "Ensuring template '$TemplateName' has Domain Computers enroll + auto-enroll"
    try {
        $tmpl = Get-CertificateTemplate -Name $TemplateName -ErrorAction Stop
    } catch {
        Write-Status "Get-CertificateTemplate requires ADCS RSAT; ensure template '$TemplateName' exists and is configured" "WARN"
        return
    }

    if (-not ($tmpl.EnrollmentFlags -band 0x4)) {
        Write-Status "Template '$TemplateName' does not have auto-enrollment flag set. Please enable it in the CA console." "WARN"
    } else {
        Write-Status "Template '$TemplateName' has auto-enrollment flag set"
    }

    $hasDomainComputers = $false
    foreach ($ace in $tmpl.SecurityDescriptor.Access) {
        if ($ace.IdentityReference -like "*Domain Computers") {
            $hasDomainComputers = $true
            break
        }
    }

    if (-not $hasDomainComputers) {
        Write-Status "Template '$TemplateName' does not appear to grant Domain Computers permissions. Please add Enroll + Autoenroll." "WARN"
    } else {
        Write-Status "Template '$TemplateName' appears to have Domain Computers ACE" 
    }
}

function Invoke-CertAutoEnrollment {
    Write-Status "Forcing Group Policy refresh"
    gpupdate.exe /force | Out-Null

    Write-Status "Triggering certificate auto-enrollment"
    certutil.exe -pulse | Out-Null
}

function Configure-WinRMHttp {
    Write-Status "Configuring WinRM HTTP listener (5985)"
    winrm quickconfig -quiet | Out-Null
    winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
    winrm set winrm/config/service/auth '@{Basic="false";Kerberos="true";Negotiate="true"}' | Out-Null
    Write-Status "WinRM HTTP configured"
}

function Configure-CredSSP {
    param(
        [string]$DomainFqdn
    )
    Write-Status "Enabling CredSSP on server side"
    Enable-WSManCredSSP -Role Server -Force | Out-Null
    Write-Status "Enabling CredSSP in WSMan service auth"
    Set-Item -Path WSMan:\localhost\Service\Auth\CredSSP -Value $true
}

function Configure-Firewall {
    Write-Status "Configuring firewall rules for WinRM and remote management"
    $rules = @(
        @{ Name = "WinRM_HTTP_5985"; Port = 5985 },
        @{ Name = "WinRM_HTTPS_5986"; Port = 5986 }
    )

    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port | Out-Null
            Write-Status "Created firewall rule $($rule.Name) on port $($rule.Port)"
        } else {
            Write-Status "Firewall rule $($rule.Name) already exists"
        }
    }

    $groups = @(
        "Remote Service Management",
        "Remote Event Log Management",
        "Remote Scheduled Tasks Management",
        "File and Printer Sharing"
    )

    foreach ($group in $groups) {
        try {
            Write-Status "Enabling firewall rule group '$group'"
            netsh advfirewall firewall set rule group="$group" new enable=Yes | Out-Null
        } catch {
            Write-Status "Failed to enable group '$group': $($_.Exception.Message)" "WARN"
        }
    }
}

function Ensure-WSManSpn {
    param(
        [string]$DomainFqdn
    )
    $hostname = $env:COMPUTERNAME
    $fqdn = "$hostname.$DomainFqdn"
    Write-Status "Ensuring WSMAN SPNs for $hostname / $fqdn"
    $computer = Get-ADComputer -Identity $hostname -Properties servicePrincipalName
    $spns = $computer.servicePrincipalName

    $needed = @(
        "WSMAN/$hostname",
        "WSMAN/$fqdn",
        "HOST/$hostname",
        "HOST/$fqdn"
    )

    $toAdd = @()
    foreach ($n in $needed) {
        if ($spns -notcontains $n) { $toAdd += $n }
    }

    if ($toAdd.Count -gt 0) {
        Write-Status "Adding SPNs: $($toAdd -join ', ')"
        foreach ($spn in $toAdd) { setspn.exe -s $spn $hostname | Out-Null }
    } else {
        Write-Status "All required SPNs already present"
    }
}

function Refresh-DomainGP {
    Write-Status "Refreshing domain Group Policy (DC)"
    gpupdate.exe /force | Out-Null
}

Write-Status "Starting Range Phase 3 builder with Role=$Role, DomainFqdn=$DomainFqdn, CaHostname=$CaHostname, TemplateName=$TemplateName"

switch ($Role) {
    'CA' {
        Test-CAReadiness -CaHostname $CaHostname -TemplateName $TemplateName
        Ensure-CATemplatePermissions -TemplateName $TemplateName
        Write-Status "CA role tasks complete"
    }
    'DC' {
        Configure-Firewall
        Ensure-WSManSpn -DomainFqdn $DomainFqdn
        Refresh-DomainGP
        Write-Status "DC role tasks complete"
    }
    'Member' {
        Configure-Firewall
        Configure-WinRMHttp
        Test-CAReadiness -CaHostname $CaHostname -TemplateName $TemplateName
        Invoke-CertAutoEnrollment
        Configure-CredSSP -DomainFqdn $DomainFqdn
        Write-Status "Member role tasks complete"
    }
}
Write-Status "Range Phase 3 builder finished successfully"
PHASE3_SCRIPT

##############################################
# INSTALL REQUIRED COLLECTIONS
##############################################
echo "[*] Installing Ansible collections"
ansible-galaxy collection install ansible.windows community.windows microsoft.ad

# ====================================================================
# PERMANENT ANSIBLE CONFIG OVERRIDE (FINGERPRINT BYPASS)
# ====================================================================
ANSIBLE_CFG_PATH="ansible.cfg"

echo "Creating optimized ansible.cfg..."
cat << EOF > "$ANSIBLE_CFG_PATH"
[defaults]
host_key_checking = False
ssh_args = -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
EOF

echo "✅ Ansible configuration optimized for rapid range rebuilds."
echo "===================================================="
echo "Repo created successfully at $REPO"
echo "===================================================="
