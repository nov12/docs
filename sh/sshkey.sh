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

# Create new user workflow
while true; do
    read -p "Please enter the new username to create (leave blank and press Enter to skip creating): " newuser
    if [ -z "$newuser" ]; then
        echo "No username entered, skipping new user workflow."
        break
    fi

    # Check if user already exists
    if id "$newuser" &>/dev/null; then
        echo "User $newuser already exists, please choose another username."
        continue
    fi

    # Create user and add to sudo group
    sudo useradd -m -s /bin/bash -G sudo "$newuser"
    if [ $? -ne 0 ]; then
        echo "Failed to create user."
        break
    fi

    # Generate a random simple password (letters and numbers, length 12)
    newpass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c12)
    echo "$newuser:$newpass" | sudo chpasswd

    # Show the password in red
    echo -e "The password for new user $newuser is: \033[31m$newpass\033[0m. Please keep it safe!"

    # Create .ssh directory and authorized_keys for the new user
    sudo -u "$newuser" mkdir -p /home/"$newuser"/.ssh
    sudo cp ~/.ssh/authorized_keys /home/"$newuser"/.ssh/authorized_keys
    sudo chown -R "$newuser":"$newuser" /home/"$newuser"/.ssh
    sudo chmod 700 /home/"$newuser"/.ssh
    sudo chmod 600 /home/"$newuser"/.ssh/authorized_keys

    # Ask whether to lock the user password
    while true; do
        read -p "Do you want to lock the password for this user (only allow SSH key login)? [Y/n] " yn
        case $yn in
            [Yy]* | "" )
                sudo passwd -l "$newuser"
                echo "Password for $newuser has been locked."
                break;;
            [Nn]* )
                echo "Password for $newuser is not locked."
                break;;
            * ) echo "Please answer [Y]es or [N]o, [Y/n]";;
        esac
    done

    break
done

sudo service ssh restart
echo "SSH key has been updated successfully."

rm -- "$0" 2>/dev/null || true

