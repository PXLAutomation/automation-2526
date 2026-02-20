# automation-2526

## Overview

This repository provides an automated environment for PXL Labs using Vagrant, Libvirt, and Ansible. It is designed to quickly spin up AlmaLinux-based virtual machines for development and testing, with infrastructure-as-code best practices.

## Directory Structure

- `default-setup/`
  - `Vagrantfile`: Defines the AlmaLinux VMs and Libvirt provider settings.
  - `inventory.ini`: Ansible inventory for the provisioned VMs.
  - `ansible.cfg`: Ansible configuration file.
  - `playbook.yml`: (Template) Ansible playbook for provisioning (customize as needed).
  - `clean_known_hosts.sh`: Script to clean SSH known_hosts entries for Vagrant-managed ports.
  - `nuke_all_vagrant.sh`: Emergency cleanup script for Vagrant and Libvirt resources.

## Quick Start

**Clone the repository:**

 ```sh
 git clone https://github.com/PXLAutomation/automation-2526.git
 cd automation-2526/default-setup
 ```

**Start the VMs:**

 ```sh
 vagrant up
 ```

**Check VM status:**

 ```sh
 vagrant status
 ```

**Test SSH access to a VM:**

```sh
vagrant ssh <vm-name>
```

Replace `<vm-name>` with the name defined in your Vagrantfile (e.g., `webserver1` or `dbserver1`).

**Run Ansible playbook:**

 ```sh
 ansible-playbook -i inventory.ini playbook.yml
 ```

**Clean up resources:**

  ```sh
  vagrant destroy -f
  ```

**Clean SSH known_hosts:**

 ```sh
 ./clean_known_hosts.sh
 ```

**Emergency cleanup of resources:**

  ```sh
  ./nuke_all_vagrant.sh
  ```

## Notes

- The default Vagrant box is `generic/alma9` (version pinned in Vagrantfile).
- SSH uses the default Vagrant insecure key.
- The Ansible playbook is a template—customize `playbook.yml` for your use case.
