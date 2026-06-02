#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Introductory-Range"
echo "[*] Creating repository engine at $REPO"
rm -rf "$REPO"
mkdir -p "$REPO"
cd "$REPO"

echo "[*] Setting up automation prerequisites"
sudo apt update
sudo apt install -y python3-pip unzip
# Fix for potential galaxy dependency resolution conflicts: Clean install matched core packages
sudo apt remove --purge -y ansible ansible-core || true
sudo apt autoremove -y
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt update
sudo apt install -y ansible net-tools
pip3 install -q pywinrm
rm -rf ~/.ansible/galaxy_cache

echo "[*] Scaffolding directory tree layout"
mkdir -p inventory/group_vars playbooks/bootstrap playbooks/roles
mkdir -p playbooks/roles/{ad-structure/{tasks,files},domain-controller/tasks,certificate-authority/tasks,windows-domain-join/tasks,windows-bootstrap/{tasks,files}}

##############################################
# INVENTORY CONTROL MATRIX
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
# GLOBAL GROUP VARIABLES
##############################################
cat > inventory/group_vars/all.yml <<'GV'
domain_name: Sorensen.Test
netbios_name: SORENSEN

domain_admin: "SORENSEN\\m.magdelena"
domain_admin_password: "10Ek!d0S[1qX*d[=o^k&"

dsrm_password: "}e5K@Z98rE_W"

cert_template: "Range-Machine"
GV

##############################################
# PHASE 1 INITIALIZATION SCRIPTS
##############################################
cat > playbooks/bootstrap/bootstrap_pre_domain.ps1 <<'BOOT'
$pass = ConvertTo-SecureString "P@ssw0rd!" -AsPlainText -Force
New-LocalUser -Name "ansible" -Password $pass -FullName "Ansible User" -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member "ansible" -ErrorAction SilentlyContinue

# Dynamic IP identification block
$IsDC = [bool](Get-NetIPAddress | Where-Object { $_.IPAddress -eq "10.10.0.10" })

if ($IsDC) {
    Write-Output "[*] Target identified as DC: Binding DNS to loopback baseline"
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ("127.0.0.1") -ErrorAction SilentlyContinue
} else {
    Write-Output "[*] Target identified as Member/CA: Routing DNS resolution via DC"
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ("10.10.0.10") -ErrorAction SilentlyContinue
}

# Safely purge stale WinRM session listeners out of active cache layers
Stop-Service WinRM -ErrorAction SilentlyContinue
winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null

winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true";CredSSP="true"}'
Start-Service WinRM -ErrorAction SilentlyContinue

New-NetFirewallRule -Name "WINRM-HTTP" -DisplayName "WINRM-HTTP" -Protocol TCP -LocalPort 5985 -Action Allow -Direction Inbound -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WINRM-HTTPS" -DisplayName "WINRM-HTTPS" -Protocol TCP -LocalPort 5986 -Action Allow -Direction Inbound -Profile Any -ErrorAction SilentlyContinue
BOOT

##############################################
# CORE MASTER PLAYBOOKS
##############################################
cat > playbooks/phase1_windows_bootstrap.yml <<'P1W'
---
- name: Phase 1 - Windows bootstrap execution via winrm
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
- name: Phase 1 - Linux bootstrap execution
  hosts: ubuntu
  become: yes
  gather_facts: yes

  tasks:
    - name: Ensure baseline ansible user exists on systems
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
# ROLE: DOMAIN CONTROLLER INFRASTRUCTURE
##############################################
cat > playbooks/roles/domain-controller/tasks/main.yml <<'DC'
---
- name: Promote node to Root Domain Controller
  microsoft.ad.domain:
    dns_domain_name: "{{ domain_name }}"
    safe_mode_password: "{{ dsrm_password }}"
    domain_netbios_name: "{{ netbios_name }}"
    install_dns: yes
  register: dc_promo

- name: Cycle system if promo rules dictate
  win_reboot:
  when: dc_promo.reboot_required

- name: Hold task block until AD DS services register active
  win_shell: |
    while (-not (Get-Service NTDS -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5 }
    while ((Get-Service NTDS).Status -ne 'Running') { Start-Sleep -Seconds 5 }
  retries: 30
  delay: 5
  register: ad_ready
  until: ad_ready.rc == 0

- name: Enforce loopback configuration for primary DC name resolution
  win_dns_client:
    adapter_names: "*"
    dns_servers:
      - 127.0.0.1
DC

##############################################
# ROLE: CERTIFICATE AUTHORITY ENGINE (HARDENED)
##############################################
cat > playbooks/roles/certificate-authority/tasks/main.yml <<'CA'
---
- name: Force CA name resolution to target DC controller explicitly
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Gate check Active Directory domain synchronization spaces
  win_shell: |
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    if ($domain) { exit 0 } else { exit 1 }
  retries: 15
  delay: 10
  register: ad_net_check
  until: ad_net_check.rc == 0

- name: Provision ADCS role components and management binaries
  win_feature:
    name: ADCS-Cert-Authority
    state: present
    include_management_tools: yes

- name: Initialize Enterprise Root Certificate Authority engine
  win_shell: Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -Force
  args:
    creates: C:\Windows\System32\CertSrv

- name: Flush DNS registration tables and force domain timeline alignment
  win_shell: |
    ipconfig /flushdns
    ipconfig /registerdns
    w32tm /resync /force
  args:
    executable: powershell.exe

- name: Register Service Principal Names for Kerberos boundary communication
  win_shell: |
    $hostName = $env:COMPUTERNAME
    $fqdn = "$hostName.{{ domain_name }}"
    setspn.exe -s "HOST/$hostName" $hostName | Out-Null
    setspn.exe -s "HOST/$fqdn" $hostName | Out-Null
    setspn.exe -s "RPCSS/$hostName" $hostName | Out-Null
    setspn.exe -s "RPCSS/$fqdn" $hostName | Out-Null
  args:
    executable: powershell.exe

- name: Harden CA DCOM descriptors to authorize cross-boundary enrollment
  win_shell: |
    $AppId = "{d99e0130-fc13-11d0-b450-00c04fc2e6c2}"
    $RegPath = "HKLM:\SOFTWARE\Classes\AppID\$AppId"
    
    net localgroup "Distributed COM Users" "SORENSEN\Domain Computers" /add 2>$null
    net localgroup "Distributed COM Users" "NT AUTHORITY\Authenticated Users" /add 2>$null
    
    if (Test-Path $RegPath) {
        Set-ItemProperty -Path $RegPath -Name "LaunchPermission" -Value ([byte[]](@())) -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $RegPath -Name "AccessPermission" -Value ([byte[]](@())) -ErrorAction SilentlyContinue
    }
    Restart-Service CertSvc -Force
  args:
    executable: powershell.exe

- name: Duplicate, modify, and publish SAN/Auto-Enroll template via native LDIF structures
  win_shell: |
    $TemplateName = "{{ cert_template }}"
    $BaseTemplate = "Computer"
    $TempDir      = "$env:TEMP\RangeTemplateBuild"
    $LdifExport   = Join-Path $TempDir "base_computer.ldf"
    $LdifImport   = Join-Path $TempDir "range_machine.ldf"

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    Write-Output "[*] Auditing active certificate template registry spaces..."
    $existing = certutil.exe -v -template | Out-String
    if ($existing -match $TemplateName) {
        Write-Output "[+] Template '$TemplateName' discovered. Refreshing publication assignments."
        certutil.exe -setcatemplates +"$TemplateName" | Out-Null
    }
    else {
        Write-Output "[*] Extracting schema parameters via LDIFDE engine..."
        Import-Module ActiveDirectory
        $configDN = (Get-ADRootDSE).configurationNamingContext
        $tmplDN   = "CN=$BaseTemplate,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configDN"

        # Stream redirected via 2>&1 into Out-Null to insulate remote WinRM handlers from lockups
        ldifde -f "$LdifExport" -d $tmplDN -p base -l "*" 2>&1 | Out-Null

        if (-not (Test-Path $LdifExport)) {
            throw "Execution error: Unable to pull baseline configuration structures via ldifde."
        }

        Write-Output "[*] Injecting target metadata fields into configuration block..."
        $content = Get-Content $LdifExport
        $content = $content -replace "CN=$BaseTemplate,", "CN=$TemplateName,"
        $content = $content -replace "displayName: $BaseTemplate", "displayName: $TemplateName"
        $content = $content -replace "templateDisplayName: $BaseTemplate", "templateDisplayName: $TemplateName"
        $content = $content | Where-Object { $_ -notmatch "^objectGUID::" }

        $content | Set-Content -Path $LdifImport -Encoding Unicode

        Write-Output "[*] Committing completed template object definitions directly to AD database..."
        ldifde -i -f "$LdifImport" 2>&1 | Out-Null

        Write-Output "[+] Exposing newly minted schema object directly to local CA container mappings..."
        certutil.exe -setcatemplates +"$TemplateName" | Out-Null
    }

    Write-Output "[*] Setting explicit SAN routing flags and workstation enrollment rights mapping parameters..."
    certutil.exe -setreg "policy\EditFlags" +EDITF_ATTRIBUTESUBJECTALTNAME2
    certutil.exe -setreg "policy\$TemplateName\AllowAttributes" +SubjectAltName
    certutil.exe -setreg policy\Machine\EnrollmentRights "+Domain Computers:Enroll"
    certutil.exe -setreg policy\Machine\EnrollmentRights "+Domain Computers:AutoEnroll"

    Write-Output "[*] Bouncing CA subsystem engine to flush Active Directory object cache lines..."
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 10

    Write-Output "[*] Running final verification query on generated template engine..."
    $verify = certutil.exe -v -template | Out-String
    if ($verify -notmatch $TemplateName) {
        throw "Validation failure: Target template structure failed to report online status following initialization sequence."
    }
  args:
    executable: powershell.exe

- name: Confirm active CA RPC endpoint tracking states
  win_shell: |
    for ($i = 1; $i -le 10; $i++) {
      Write-Output "Evaluating CA pipeline accessibility status (Attempt $i/10)..."
      $out = certutil.exe -ping 2>&1
      if ($LASTEXITCODE -eq 0 -and $out -match "Ping successfully completed") {
        Write-Output "[+] Verification match: Target CA RPC pathways report active."
        exit 0
      }
      Start-Sleep -Seconds 6
    }
    throw "Critical failure: Subsystem channel communication timeout encountered."
  args:
    executable: powershell.exe

- name: Initialize early local HTTPS listener assignment on CA node (Optional verification gate)
  win_shell: |
    gpupdate.exe /force
    certutil.exe -pulse

    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
      $_.Extensions | Where-Object {
        $_.Oid.FriendlyName -eq "Enhanced Key Usage" -and
        $_.Format(0) -match "Server Authentication"
      }
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

    if ($cert) {
      winrm delete winrm/config/Listener?Address=*+Transport=HTTPS 2>$null
      winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME.{{ domain_name }}`"; CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    } else {
      throw "Deployment halt: System unable to verify or locate valid Server Authentication certificates."
    }
  args:
    executable: powershell.exe
CA

##############################################
# ROLE: ACTIVE DIRECTORY STRUCTURE & AUTOENROLL GPO
##############################################
cat > playbooks/roles/ad-structure/tasks/main.yml <<'ADMAIN'
---
- import_tasks: ou_groups.yml
- import_tasks: users.yml

- name: Deploy Domain-Wide Automated Certificate Enrollment Group Policy
  win_shell: |
    Import-Module GroupPolicy
    $GpoName = "Enterprise-AutoEnrollment-Policy"
    
    if (-not (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue)) {
        $gpo = New-GPO -Name $GpoName -Comment "Enforces automatic workstation certificate enrollment from Range CA"
        New-GPLink -Name $GpoName -Target "DC=Sorensen,DC=Test" -LinkEnabled Yes
        
        Set-GPRegistryValue -Name $GpoName -Key "HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "AEPolicy" -Type DWord -Value 7
    }
  ignore_errors: yes
ADMAIN

cat > playbooks/roles/ad-structure/tasks/ou_groups.yml <<'OUG'
---
- name: Establish base administrative service credentials
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

- name: Provision structural security group containers
  microsoft.ad.ou:
    name: Base Groups
    path: "DC=Sorensen,DC=Test"
    state: present

- name: Build primary systemic isolation tiers
  microsoft.ad.group:
    name: "{{ item }}"
    path: "OU=Base Groups,DC=Sorensen,DC=Test"
    scope: global
  loop:
    - Workstations
    - Servers

- name: Scaffold divisional organization tree root
  microsoft.ad.ou:
    name: Departments
    path: "DC=Sorensen,DC=Test"
    state: present

- name: Expand nested organizational business unit branches
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

- name: Instantiate functional domain security groups
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
- name: Ingest identity information dataset files
  include_vars:
    file: ../ad-structure/files/domain_users.yml
    name: users_data

- name: Flatten target data schemas for structural validation loops
  set_fact:
    flat_users: "{{ users_data.users | map(attribute='user_info') | flatten }}"

- name: Populate organizational units with target user identities
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
      - { first_name: 'Irvin', surname: 'Holland', username: 'j0YY728sTw8A', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Myla', surname: 'Sosa', username: 'm.sosa', password: 'UxzS7Ir60mJO', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Kamari', surname: 'Johnson', username: 'k.johnson', password: '6lzz0TCC3CgH', domain_groups: ['Mgmnt Staff'] }
      - { first_name: 'Lacey', surname: 'Potter', username: 'l.potter', password: 't61w42Gf5snK', domain_groups: ['Mgmnt Staff'] }
USERFILE

##############################################
# ROLE: SECURE WORKSTATION DOMAIN JOIN JOIN
##############################################
cat > playbooks/roles/windows-domain-join/tasks/main.yml <<'JOIN'
---
- name: Establish primary domain name resolution pointers
  win_dns_client:
    adapter_names: "*"
    dns_servers: "10.10.0.10"

- name: Bind node instance to Sorensen.Test enterprise domain boundary
  microsoft.ad.membership:
    dns_domain_name: "{{ domain_name }}"
    domain_admin_user: "{{ domain_admin }}"
    domain_admin_password: "{{ domain_admin_password }}"
    state: domain
  register: domain_join

- name: Trigger hardware cycle upon membership modification requirements
  win_reboot:
  when: domain_join.reboot_required
JOIN

##############################################
# ROLE: PHASE 3 MANAGEMENT PIPELINE UPGRADE
##############################################
cat > playbooks/roles/windows-bootstrap/tasks/main.yml <<'WB'
---
- name: Stage Phase 3 orchestration script payload on node filesystem
  ansible.windows.win_copy:
    src: Range-Phase3-Builder.ps1
    dest: C:\Range-Phase3-Builder.ps1

- name: Align WinRM configuration frameworks and open management ports
  ansible.windows.win_shell: |
    winrm quickconfig -q
    winrm set winrm/config/service '@{AllowUnencrypted="false"}'
    winrm set winrm/config/service/auth '@{Basic="false";Kerberos="true";Negotiate="true"}'
    if (-not (Get-NetFirewallRule -DisplayName "WinRM_HTTP_5985" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName "WinRM_HTTP_5985" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 | Out-Null
    }
  args:
    executable: powershell.exe

- name: Launch Phase 3 orchestration helper blocks — Domain Controller Target context
  ansible.windows.win_shell: |
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 `
      -Role DC `
      -DomainFqdn "{{ domain_name }}" `
      -CaHostname "ca01" `
      -TemplateName "{{ cert_template }}"
  when: inventory_hostname == 'domain_controller'

- name: Launch Phase 3 orchestration helper blocks — Certificate Authority Target context
  ansible.windows.win_shell: |
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 `
      -Role CA `
      -DomainFqdn "{{ domain_name }}" `
      -CaHostname "ca01" `
      -TemplateName "{{ cert_template }}"
  when: inventory_hostname == 'certificate_authority'

- name: Launch Phase 3 orchestration helper blocks — Member Workstation context
  ansible.windows.win_shell: |
    # 1. Execute system isolation parameter verification layers
    powershell.exe -ExecutionPolicy Bypass -File C:\Range-Phase3-Builder.ps1 -Role Member -DomainFqdn "{{ domain_name }}" -CaHostname "ca01" -TemplateName "{{ cert_template }}"
    
    # 2. Trigger GPO synchronization engines to pull updated enrollment scopes
    gpupdate.exe /force
    certutil.exe -pulse
    
    # 3. Pull machine identity credentials natively using the Local System token
    $cert = Get-Certificate -Template "{{ cert_template }}" -Url "LDAP:" -CertStoreLocation "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue
    
    # 4. Extract top valid server authentication credential thumbprints from system stores
    $finalCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Enhanced Key Usage" -and $_.Format(0) -match "Server Authentication" }
    } | Sort-Object NotBefore -Descending | Select-Object -First 1
    
    if ($finalCert) {
        winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME.{{ domain_name }}`"; CertificateThumbprint=`"$($finalCert.Thumbprint)`"}"
    } else {
        throw "Deployment failure: Workstation was unable to pull credentials via active auto-enrollment partitions."
    }
  when: inventory_hostname != 'domain_controller' and inventory_hostname != 'certificate_authority'

- name: Pivot runtime variables to use secure HTTPS transportation targets
  set_fact:
    ansible_port: 5986
    ansible_winrm_transport: credssp
    ansible_winrm_server_cert_validation: ignore

- name: Hard-reset active session pipeline interfaces to load updated configuration parameters
  meta: reset_connection

- name: Purge insecure flat HTTP transportation channel definitions from runtime environments
  ansible.windows.win_shell: |
    winrm delete winrm/config/Listener?Address=*+Transport=HTTP 2>$null
  args:
    executable: powershell.exe

- name: Confirm end-to-end transport validation
  win_ping:
WB

# Inject Phase 3 Management Pipeline Transition Script
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
        [int]$MaxAttempts = 12,
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
                throw "Exceeded maximum deployment validation execution thresholds for: $Description"
            }
        }
    }
}

function Test-CAReadiness {
    param(
        [string]$CaHostname,
        [string]$TemplateName
    )

    Write-Status "Running transport availability checks against CA RPC components..."
    Invoke-WithRetry -Description "Ping CA RPC Endpoint Structure" -ScriptBlock {
        certutil.exe -ping $CaHostname | Out-Null
    }

    Write-Status "Evaluating directory replication levels for template signature validation: '$TemplateName'"
    Invoke-WithRetry -Description "AD Schema Replication Gate" -ScriptBlock {
        $templates = certutil.exe -config "$CaHostname\CA" -template | Out-String
        if ($templates -notmatch [regex]::Escape($TemplateName)) {
            throw "Target certificate structure template configuration token '$TemplateName' has not populated active directory caches."
        }
    }
}

function Configure-WinRMHttp {
    Write-Status "Hardening existing WinRM configuration channel specifications"
    winrm quickconfig -quiet | Out-Null
    winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
    winrm set winrm/config/service/auth '@{Basic="false";Kerberos="true";Negotiate="true"}' | Out-Null
}

function Configure-CredSSP {
    param(
        [string]$DomainFqdn
    )
    Write-Status "Enabling credential delegation transport boundaries (CredSSP)"
    Enable-WSManCredSSP -Role Server -Force | Out-Null
    Set-Item -Path WSMan:\localhost\Service\Auth\CredSSP -Value $true
}

function Configure-Firewall {
    Write-Status "Aligning packet filtration security baseline definitions"
    $rules = @(
        @{ Name = "WinRM_HTTP_5985"; Port = 5985 },
        @{ Name = "WinRM_HTTPS_5986"; Port = 5986 }
    )

    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port | Out-Null
        }
    }

    $groups = @(
        "Remote Service Management",
        "Remote Event Log Management",
        "Remote Scheduled Tasks Management",
        "File and Printer Sharing"
    )

    foreach ($group in $groups) {
        netsh advfirewall firewall set rule group="$group" new enable=Yes | Out-Null
    }
}

function Ensure-WSManSpn {
    param(
        [string]$DomainFqdn
    )
    $hostname = $env:COMPUTERNAME
    $fqdn = "$hostname.$DomainFqdn"
    Write-Status "Validating Service Principal Name declarations for $fqdn"
    
    $needed = @("WSMAN/$hostname", "WSMAN/$fqdn", "HOST/$hostname", "HOST/$fqdn")
    foreach ($spn in $needed) { 
        setspn.exe -s $spn $hostname | Out-Null 
    }
}

switch ($Role) {
    'CA' {
        Write-Status "Registering Kerberos service principal names for CA instance components..."
        setspn.exe -s "HOST/$env:COMPUTERNAME" $env:COMPUTERNAME | Out-Null
        setspn.exe -s "HOST/$env:COMPUTERNAME.$DomainFqdn" $env:COMPUTERNAME | Out-Null
        setspn.exe -s "RPCSS/$env:COMPUTERNAME" $env:COMPUTERNAME | Out-Null
        setspn.exe -s "RPCSS/$env:COMPUTERNAME.$DomainFqdn" $env:COMPUTERNAME | Out-Null
        
        Test-CAReadiness -CaHostname $CaHostname -TemplateName $TemplateName
        Write-Status "CA instance security configurations report functional."
    }
    'DC' {
        Configure-Firewall
        Ensure-WSManSpn -DomainFqdn $DomainFqdn
        gpupdate.exe /force | Out-Null
        Write-Status "DC baseline operational rulesets report verified."
    }
    'Member' {
        Configure-Firewall
        Configure-WinRMHttp
        Test-CAReadiness -CaHostname $CaHostname -TemplateName $TemplateName
        Configure-CredSSP -DomainFqdn $DomainFqdn
        Write-Status "Workstation node baseline structures successfully verified."
    }
}
Write-Status "Verification framework sequence reached completion successfully"
PHASE3_SCRIPT

##############################################
# ANSIBLE GALAXY RESOURCE COLLECTION DEPENDENCIES
##############################################
echo "[*] Ingesting necessary external collection bundles"
ansible-galaxy collection install ansible.windows community.windows microsoft.ad

# ====================================================================
# SPEED ENGINE OPTIMIZATIONS (SSH/SSL BYPASS MATRIX)
# ====================================================================
ANSIBLE_CFG_PATH="ansible.cfg"

echo "Writing pipeline optimization configuration data parameters to ansible.cfg..."
cat << EOF > "$ANSIBLE_CFG_PATH"
[defaults]
host_key_checking = False
ssh_args = -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
EOF

echo "✅ Deployment engineering assets constructed successfully. Target range initialization available inside $REPO."
echo "======================================================================================================="
