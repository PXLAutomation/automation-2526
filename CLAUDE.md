# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides infrastructure-as-code for PXL Labs to spin up AlmaLinux 9 virtual machines using **Vagrant + Libvirt/KVM** with **Ansible** for configuration management. All working files are under `default-setup/` — run all commands from that directory.

## Two VMs Provisioned

| VM | Hostname | IP | Forwarded Port |
|----|----------|----|----------------|
| webserver1 | webserver1.pxldemo.local | 192.168.121.100 | 8080 → 8080 |
| dbserver1 | dbserver1.pxldemo.local | 192.168.121.101 | — |

Box: `generic/alma9` version `4.3.12` (hard-pinned). SSH uses the shared Vagrant insecure key (`~/.vagrant.d/insecure_private_key`).

## Common Commands

All commands run from `default-setup/`:

```sh
vagrant up                                      # Start all VMs
vagrant up webserver1                           # Start a single VM
vagrant status                                  # Check VM state
vagrant ssh webserver1                          # SSH into a VM
vagrant destroy -f                              # Destroy all VMs

ansible-playbook -i inventory.ini playbook.yml  # Run the Ansible playbook
ansible-lint                                    # Lint the playbook

./clean_known_hosts.sh                          # Remove SSH known_hosts entries for Vagrant ports
./nuke_all_vagrant.sh                           # Dry-run cleanup (safe preview)
./nuke_all_vagrant.sh --force                   # Destructively remove all Vagrant/libvirt resources
```

## Architecture Notes

- **Vagrantfile**: Defines both VMs with shared libvirt provider settings (2GB RAM, 2 CPUs, 40GB qcow2 disk). Also updates the *host machine's* `/etc/hosts` via a post-up trigger, and each *guest's* `/etc/hosts` via shell provisioner — both idempotent (guarded by `PXL_LAB_BEGIN` marker).
- **playbook.yml**: Currently a template (only contains YAML header). Customize this for provisioning tasks.
- **inventory.ini**: Maps VM names to SSH ports (webserver1→2222, dbserver1→2200) using the Vagrant insecure key.
- **ansible.cfg**: Points to `inventory.ini` and disables host key checking.
- **.ansible-lint**: Skips name casing, template, and FQCN rules to avoid conflicts with Vagrant's conventions.
- **nuke_all_vagrant.sh**: Defaults to dry-run; requires `--force` to execute. Use for emergency cleanup when `vagrant destroy` fails.
- **clean_known_hosts.sh**: Removes SSH known_hosts entries for ports 2200–2202 and 2222 by default; supports `--dry-run` and custom hosts/ports.
