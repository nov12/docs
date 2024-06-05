#!/bin/bash

# URL to download
url="https://github.com/nov12.keys"

# Use wget to download the content
wget -O keys $url

# Check if wget command succeeded
if [ $? -ne 0 ]; then
    echo "Error: Failed to download from $url"
    exit 1
fi

# Ask user whether to overwrite the ssh key file
while true; do
    read -p "Do you want to overwrite the ssh key file? [Y/n] " yn
    case $yn in
        [Yy]* | "" ) cat keys > ~/.ssh/authorized_keys; rm keys; break;;
        [Nn]* ) cat keys >> ~/.ssh/authorized_keys; break;;
        * ) echo "Please answer [Y]es or [N]o, [Y/n]";;
    esac
done

# Ask user whether to disable ssh password login
while true; do
    read -p "Do you want to disable ssh password login? [Y/n] " yn
    case $yn in
        [Yy]* | "" ) sudo sed -i 's/^#\?\(PasswordAuthentication yes\)/PasswordAuthentication no/g' /etc/ssh/sshd_config; break;;
        [Nn]* ) break;;
        * ) echo "Please answer [Y]es or [N]o, [Y/n]";;
    esac
done

# Ask user to enter the ssh port
while true; do
    read -p "Enter the ssh port [default: 2022]: " port
    port=${port:-2022}
    if [[ $port -ge 22 && $port -le 65534 ]]; then
        sudo sed -i "s/#Port 22/Port $port/g" /etc/ssh/sshd_config
        sudo service ssh restart
        break
    else
        echo "Please enter a number between 22 and 65534."
    fi
done

# Ask user whether to change the current user's password
while true; do
    read -p "Do you want to change the current user's password? [Y/n] " yn
    case $yn in
        [Yy]* | "" ) 
            new_password=$(tr -dc 'a-zA-Z0-9!@#$%^&*()-+=' < /dev/urandom | fold -w 16 | head -n 1)
            echo -e "$USER:$new_password" | sudo chpasswd
            echo -e "Your new password is: \033[31m$new_password\033[0m. Please save it."
            break;;
        [Nn]* ) break;;
        * ) echo "Please answer [Y]es or [N]o, [Y/n]";;
    esac
done

sudo service ssh restart
echo "SSH key has been updated successfully."
