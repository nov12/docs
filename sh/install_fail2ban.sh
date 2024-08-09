#!/bin/bash

# Update package list and install ufw
sudo apt-get update && sudo apt-get install ufw -y

# Enable ufw
sudo systemctl enable ufw
sudo ufw enable

# Allow sshd port (default is 22)
sudo ufw allow ssh

# Get the default sshd port from the sshd_config file
SSHD_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')

# Allow the sshd port
sudo ufw allow $SSHD_PORT

# Check ufw status
sudo ufw status

# Install fail2ban
sudo apt-get install fail2ban -y

# Download custom fail2ban configuration to /tmp
wget -P /tmp https://github.com/nov12/docs/raw/main/config/fail2ban/jail.local

# Move the custom configuration to the correct location
sudo mv /tmp/jail.local /etc/fail2ban/

# Restart fail2ban to apply the new configuration
sudo service fail2ban restart
