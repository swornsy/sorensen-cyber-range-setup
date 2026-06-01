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
$pass = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force
New-LocalUser -Name "ansible" -Password $pass -FullName "Ansible User" -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "ansible" -ErrorAction SilentlyContinue

winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true";CredSSP="true"}'

# Pre-stage both WinRM firewall rules early so both ports are network-accessible
New-NetFirewallRule -Name "WINRM-HTTP" -DisplayName "WINRM-HTTP" -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WINRM-HTTPS" -DisplayName "WINRM-HTTPS" -Protocol TCP -LocalPort 5986 -Action Allow -Direction Inbound -ErrorAction SilentlyContinue
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
# POST-DOMAIN BOOTSTRAP ROLE (HARDENED)
##############################################
cat > playbooks/roles/windows-bootstrap/tasks/main.yml <<'WB'
---
- name: Copy post-domain bootstrap script
  win_copy:
    src: bootstrap-win-post-domain.ps1
    dest: C:\bootstrap-win-post-domain.ps1

- name: Ensure WinRM HTTPS Firewall Port 5986 is open
  win_shell: |
    New-NetFirewallRule -Name "WINRM-HTTPS" -DisplayName "WINRM-HTTPS" -Protocol TCP -LocalPort 5986 -Action Allow -Direction Inbound -ErrorAction SilentlyContinue
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    exit 0

# Synchronously execute script to prevent race conditions or dropped connections
- name: Run post-domain bootstrap script to shift to HTTPS
  win_shell: powershell.exe -ExecutionPolicy Bypass -File C:\bootstrap-win-post-domain.ps1

- name: Wait for certificate generation and listener migration
  pause:
    seconds: 15

- name: Dynamically migrate host connection details to HTTPS
  set_fact:
    ansible_port: 5986
    ansible_winrm_transport: basic
    ansible_winrm_server_cert_validation: ignore

- name: Force Ansible connection engine reset
  meta: reset_connection

- name: Validate secure HTTPS connectivity channel
  win_ping:
WB

# Hardened Self-Signed deployment script payload
cat > playbooks/roles/windows-bootstrap/files/bootstrap-win-post-domain.ps1 <<'WBPS'
<#
.SYNOPSIS
    Hardened Post-Domain Join Bootstrap Script for Windows Range Targets.
    Decoupled from Enterprise CA for WinRM layer to prevent double-hop lockouts.
#>
Write-Output "=========================================================="
Write-Output " Hardened WinRM HTTPS Port 5986 Provisioning Engine "
Write-Output "=========================================================="

# 1. Force WinRM service context alive and clean
Set-Service WinRM -StartupType Automatic
Restart-Service WinRM -Force

# 2. Generate an isolated local cryptographic token for the management socket
try {
    $LocalCert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation "Cert:\LocalMachine\My" -KeyLength 2048 -Provider "Microsoft RSA SChannel Cryptographic Provider" -Type "SSLServerAuthentication" -ErrorAction Stop
    $Thumbprint = $LocalCert.Thumbprint
    Write-Output "[+] Generated Local Cryptographic Management Token: $Thumbprint"
} catch {
    Write-Error "[-] CRITICAL: Local certificate generation failed: $($_.Exception.Message)"
    Exit 1
}

# 3. Purge existing unencrypted/broken configurations
Write-Output "[*] Flushing legacy WinRM communication pipelines..."
winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null

# 4. Rebuild the listener block securely using the exact thumbprint string variable
Write-Output "[*] Registering pristine HTTPS network socket binding..."
try {
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`"; CertificateThumbprint=`"$Thumbprint`"}"
    Write-Output "[+] WinRM HTTPS listener successfully bound to port 5986."
} catch {
    Write-Error "[-] CRITICAL: Failed to bind WinRM HTTPS socket: $($_.Exception.Message)"
    Exit 1
}

# 5. Lock down Windows Firewall configuration parameters
Write-Output "[*] Hardening firewall parameters..."
New-NetFirewallRule -Name "WINRM-HTTPS-MANAGEMENT" -DisplayName "Hardened WinRM HTTPS Port 5986 (Ansible Control)" -Protocol TCP -LocalPort 5986 -Action Allow -Direction Inbound -Profile Any -ErrorAction SilentlyContinue

# Disable old legacy unencrypted hole
Disable-NetFirewallRule -DisplayName "Windows Remote Management (HTTP-In)" -ErrorAction SilentlyContinue

# 6. Final service kick to cement bindings
Restart-Service WinRM -Force
Write-Output "[+] Aligned successfully on HTTPS port 5986."
WBPS

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
