#!/bin/bash

#  torgap-demo.sh - Installs torgap-demo behind a tor address derived from a minisign secret key
#  Key conversion is made by torgap-sig-cli-rust.
#  Once set up, onion service offers to download and verify a signed text file.
#
#  Created by @gorazdko 2020-11-19
#
#  https://github.com/BlockchainCommons/torgap-demo
#  https://github.com/BlockchainCommons/torgap-sig-cli-rust
#
#  Based on LinodeStandUp.sh by Peter Denton
#  source: https://github.com/BlockchainCommons/Bitcoin-Standup-Scripts/blob/master/Scripts/LinodeStandUp.sh


# It is highly recommended to add a Tor V3 pubkey for cookie authentication.
# It is also recommended to delete the /standup.log, and
# /standup.err files.

# torgap-demo.sh sets Tor and torgap-demo as systemd services so that they
# start automatically after crashes or reboots. If you supply a SSH_KEY in
# the arguments it allows you to easily access your node via SSH using your rsa
# pubkey, if you add SYS_SSH_IP's it will only accept SSH connections from those
# IP's.

# torgap-demo.sh will create a user called standup, and assign the optional
# password you give it in the arguments.

# torgap-demo.sh will create two logs in your root directory, to read them run:
# $ cat standup.err
# $ cat standup.log

# This block defines the variables the user of the script needs to input
# when deploying using this script.
#
# <UDF name="torV3AuthKey" Label="x25519 Public Key" default="" example="descriptor:x25519:JBFKJBEUF72387RH2UHDJFHIUWH47R72UH3I2UHD" optional="true"/>
# PUBKEY=
# <UDF name="btctype" label="Bitcoin Core Installation Type" oneOf="None, Mainnet,Pruned Mainnet,Testnet,Pruned Testnet,Private Regtest" default="None" example="Bitcoin node type. If None, timestamp verification will be performed by a public Esplora explorer" optional="true"/>
# BTCTYPE=
# <UDF name="userpassword" label="StandUp Password" example="Password to for the standup non-privileged account." />
# USERPASSWORD=
# <UDF name="ssh_key" label="SSH Key" default="" example="Key for automated logins to standup non-privileged account." optional="true" />
# SSH_KEY=
# <UDF name="sys_ssh_ip" label="SSH-Allowed IPs" default="" example="Comma separated list of IPs that can use SSH" optional="true" />
# SYS_SSH_IP=
# <UDF name="region" label="Timezone" oneOf="Asia/Singapore,America/Los_Angeles" default="America/Los_Angeles" example="Servers location" optional="false"/>
# REGION=



# Force check for root, if you are not logged in as root then the script will not execute
if ! [ "$(id -u)" = 0 ]
then

  echo "$0 - You need to be logged in as root!"
  exit 1
  
fi


# CURRENT BITCOIN RELEASE:
# Change as necessary
export BITCOIN="bitcoin-core-0.20.1"


# Output stdout and stderr to ~root files
exec > >(tee -a /root/standup.log) 2> >(tee -a /root/standup.log /root/standup.err >&2)

####
# 2. Update Timezone
####

# Set Timezone

echo "$0 - Set Time Zone to $REGION"

echo $REGION > /etc/timezone
cp /usr/share/zoneinfo/${REGION} /etc/localtime

####
# 3. Bring Debian Up To Date
####

echo "$0 - Starting Debian updates; this will take a while!"

# Make sure all packages are up-to-date
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y

# Install haveged (a random number generator)
apt-get install haveged -y

# Install GPG
apt-get install gnupg -y

apt-get install -y cmake build-essential

# Set system to automatically update
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
apt-get -y install unattended-upgrades

echo "$0 - Updated Debian Packages"

# get uncomplicated firewall and deny all incoming connections except SSH
sudo apt-get install ufw -y
ufw allow ssh
ufw enable

####
# 4. Set Up User
####

# Create "standup" user with optional password and give them sudo capability
/usr/sbin/useradd -m -p `perl -e 'printf("%s\n",crypt($ARGV[0],"password"))' "$USERPASSWORD"` -g sudo -s /bin/bash standup
/usr/sbin/adduser standup sudo

echo "$0 - Setup standup with sudo access."

# Setup SSH Key if the user added one as an argument
if [ -n "$SSH_KEY" ]
then

   mkdir ~standup/.ssh
   echo "$SSH_KEY" >> ~standup/.ssh/authorized_keys
   chown -R standup ~standup/.ssh

   echo "$0 - Added .ssh key to standup."

fi

# Setup SSH allowed IP's if the user added any as an argument
if [ -n "$SYS_SSH_IP" ]
then

  echo "sshd: $SYS_SSH_IP" >> /etc/hosts.allow
  echo "sshd: ALL" >> /etc/hosts.deny
  echo "$0 - Limited SSH access."

else

  echo "$0 - WARNING: Your SSH access is not limited; this is a major security hole!"

fi


sudo apt install -y build-essential
curl -sL https://raw.githubusercontent.com/creationix/nvm/v0.35.3/install.sh -o install_nvm.sh
bash install_nvm.sh

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

echo "installing node"
nvm install node
node --version

# node version is important as it is hardcoed in systemctl service file
nvm install 15.4.0
nvm use 15.4.0

echo "installing opentimestamps"
npm install -g opentimestamps
ots-cli.js -h


###### install rust and cargo
cd $HOME
apt-get install -y git curl
curl https://sh.rustup.rs -sSf > rust_install.sh
chmod +x rust_install.sh
./rust_install.sh -y
export PATH=$HOME/.cargo/bin:$PATH


###### Install https://github.com/BlockchainCommons/torgap-opentimestamps.git
cd ~standup
git clone https://github.com/BlockchainCommons/torgap-opentimestamps.git
pushd torgap-opentimestamps
cargo build --release
popd
chown -R standup torgap-opentimestamps


if [[ "$BTCTYPE" != "None" ]]; then
	OTS_FLAG="bitcoind"
else
	OTS_FLAG="none"
fi

# Setup torgap-opentimestamps as a service
echo "$0 - Setting up torgap-opentimestamps as a systemd service."

# we need torgap-demo path. The script executed is in torgap-demo/StackScript
sudo cat > /etc/systemd/system/torgap-opentimestamps.service << EOF
[Unit]
Description=opentimestamps server torgapped
After=tor.service
Requires=tor.service

[Service]
Type=simple
Restart=always
User=root
Environment=PATH=/home/someUser/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.nvm/versions/node/v15.4.0/bin
EnvironmentFile=/root/.nvm/versions/node/v15.4.0/bin/ots-cli.js
ExecStart=/home/standup/torgap-opentimestamps/target/release/torgap-opentimestamps $OTS_FLAG

[Install]
WantedBy=multi-user.target

EOF


####
# 5. Install latest stable tor
####

# Download tor

#  To use source lines with https:// in /etc/apt/sources.list the apt-transport-https package is required. Install it with:
sudo apt install apt-transport-https -y

# We need to set up our package repository before you can fetch Tor. First, you need to figure out the name of your distribution:
DEBIAN_VERSION=$(lsb_release -c | awk '{ print $2 }')

# You need to add the following entries to /etc/apt/sources.list:
cat >> /etc/apt/sources.list << EOF
deb https://deb.torproject.org/torproject.org $DEBIAN_VERSION main
deb-src https://deb.torproject.org/torproject.org $DEBIAN_VERSION main
EOF

# Then add the gpg key used to sign the packages by running:
sudo curl https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --import
sudo gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -

# Update system, install and run tor as a service
sudo apt update -y
sudo apt install tor deb.torproject.org-keyring -y

# Setup hidden service

sed -i -e 's/#ControlPort 9051/ControlPort 9051/g' /etc/tor/torrc

sed -i -e 's/#CookieAuthentication 1/CookieAuthentication 1/g' /etc/tor/torrc

sed -i -e 's/## address y:z./## address y:z.\
\
HiddenServiceDir \/var\/lib\/tor\/torgap-opentimestamps\/\
HiddenServiceVersion 3\
HiddenServicePort 80 127.0.0.1:7777/g' /etc/tor/torrc

mkdir /var/lib/tor/torgap-opentimestamps
chown -R debian-tor:debian-tor /var/lib/tor/torgap-opentimestamps
chmod 700 /var/lib/tor/torgap-opentimestamps


# Add standup to the tor group
sudo usermod -a -G debian-tor standup

echo "$0 - Starting torgap-opentimestamps service"
systemctl daemon-reload
systemctl enable torgap-opentimestamps.service
systemctl start torgap-opentimestamps.service

sudo systemctl restart tor.service


# add V3 authorized_clients public key if one exists
if ! [[ $PUBKEY == "" ]]
then

  # create the directory manually in case tor.service did not restart quickly enough
  mkdir /var/lib/tor/standup/authorized_clients

  # Create the file for the pubkey
  sudo touch /var/lib/tor/standup/authorized_clients/fullynoded.auth

  # Write the pubkey to the file
  sudo echo $PUBKEY > /var/lib/tor/standup/authorized_clients/fullynoded.auth

  # Restart tor for authentication to take effect
  sudo systemctl restart tor.service

  echo "$0 - Successfully added Tor V3 authentication"

else

  echo "$0 - No Tor V3 authentication, anyone who gets access may see your service"

fi




####
# 6. Install Bitcoin
####

if [[ "$BTCTYPE" != "None" ]]; then

# Download Bitcoin
echo "$0 - Downloading Bitcoin; this will also take a while!"

export BITCOINPLAIN=`echo $BITCOIN | sed 's/bitcoin-core/bitcoin/'`

sudo -u standup wget https://bitcoincore.org/bin/$BITCOIN/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz -O ~standup/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz
sudo -u standup wget https://bitcoincore.org/bin/$BITCOIN/SHA256SUMS.asc -O ~standup/SHA256SUMS.asc
sudo -u standup wget https://bitcoin.org/laanwj-releases.asc -O ~standup/laanwj-releases.asc

# Verifying Bitcoin: Signature
echo "$0 - Verifying Bitcoin."

sudo -u standup /usr/bin/gpg --no-tty --import ~standup/laanwj-releases.asc
export SHASIG=`sudo -u standup /usr/bin/gpg --no-tty --verify ~standup/SHA256SUMS.asc 2>&1 | grep "Good signature"`
echo "SHASIG is $SHASIG"

if [ "$SHASIG" ]
then

    echo "$0 - VERIFICATION SUCCESS / SIG: $SHASIG"
    
else

    (>&2 echo "$0 - VERIFICATION ERROR: Signature for Bitcoin did not verify!")
    
fi

# Verify Bitcoin: SHA
export TARSHA256=`/usr/bin/sha256sum ~standup/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz | awk '{print $1}'`
export EXPECTEDSHA256=`cat ~standup/SHA256SUMS.asc | grep $BITCOINPLAIN-x86_64-linux-gnu.tar.gz | awk '{print $1}'`

if [[ "$TARSHA256" == "$EXPECTEDSHA256" ]]
then

   echo "$0 - VERIFICATION SUCCESS / SHA: $TARSHA256"
   
else

    (>&2 echo "$0 - VERIFICATION ERROR: SHA for Bitcoin did not match!")
    
fi

# Install Bitcoin
echo "$0 - Installing Bitcoin."

sudo -u standup /bin/tar xzf ~standup/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz -C ~standup
/usr/bin/install -m 0755 -o root -g root -t /usr/local/bin ~standup/$BITCOINPLAIN/bin/*
/bin/rm -rf ~standup/$BITCOINPLAIN/

# Start Up Bitcoin
echo "$0 - Configuring Bitcoin."

sudo -u standup /bin/mkdir ~standup/.bitcoin

# The only variation between Mainnet and Testnet is that Testnet has the "testnet=1" variable
# The only variation between Regular and Pruned is that Pruned has the "prune=550" variable, which is the smallest possible prune
RPCPASSWORD=$(xxd -l 16 -p /dev/urandom)

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
server=1
dbcache=1536
par=1
maxuploadtarget=137
maxconnections=16
rpcuser=StandUp
rpcpassword=$RPCPASSWORD
rpcallowip=127.0.0.1
debug=tor
EOF

# This is a hack for ots-cli.js to work properly, as it is looking for a config file
# in a wrong place when run with root
mkdir $HOME/.bitcoin
ln -s ~standup/.bitcoin/bitcoin.conf $HOME/.bitcoin/bitcoin.conf

if [[ "$BTCTYPE" == "" ]]; then

BTCTYPE="Pruned Testnet"

fi

if [[ "$BTCTYPE" == "Mainnet" ]]; then

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
txindex=1
EOF

elif [[ "$BTCTYPE" == "Pruned Mainnet" ]]; then

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
prune=550
EOF

elif [[ "$BTCTYPE" == "Testnet" ]]; then

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
txindex=1
testnet=1
EOF

elif [[ "$BTCTYPE" == "Pruned Testnet" ]]; then

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
prune=550
testnet=1
EOF

elif [[ "$BTCTYPE" == "Private Regtest" ]]; then

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
regtest=1
txindex=1
EOF

else

  (>&2 echo "$0 - ERROR: Somehow you managed to select no Bitcoin Installation Type, so Bitcoin hasn't been properly setup. Whoops!")
  exit 1

fi

cat >> ~standup/.bitcoin/bitcoin.conf << EOF
[test]
rpcbind=127.0.0.1
rpcport=18332
[main]
rpcbind=127.0.0.1
rpcport=8332
[regtest]
rpcbind=127.0.0.1
rpcport=18443
EOF

/bin/chown standup ~standup/.bitcoin/bitcoin.conf
/bin/chmod 600 ~standup/.bitcoin/bitcoin.conf

# Setup bitcoind as a service that requires Tor
echo "$0 - Setting up Bitcoin as a systemd service."

sudo cat > /etc/systemd/system/bitcoind.service << EOF
# It is not recommended to modify this file in-place, because it will
# be overwritten during package upgrades. If you want to add further
# options or overwrite existing ones then use
# $ systemctl edit bitcoind.service
# See "man systemd.service" for details.
# Note that almost all daemon options could be specified in
# /etc/bitcoin/bitcoin.conf, except for those explicitly specified as arguments
# in ExecStart=
[Unit]
Description=Bitcoin daemon
After=tor.service
Requires=tor.service
[Service]
ExecStart=/usr/local/bin/bitcoind -conf=/home/standup/.bitcoin/bitcoin.conf
# Process management
####################
Type=simple
PIDFile=/run/bitcoind/bitcoind.pid
Restart=on-failure
# Directory creation and permissions
####################################
# Run as bitcoin:bitcoin
User=standup
Group=sudo
# /run/bitcoind
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710
# Hardening measures
####################
# Provide a private /tmp and /var/tmp.
PrivateTmp=true
# Mount /usr, /boot/ and /etc read-only for the process.
ProtectSystem=full
# Disallow the process and all of its children to gain
# new privileges through execve().
NoNewPrivileges=true
# Use a new /dev namespace only populated with API pseudo devices
# such as /dev/null, /dev/zero and /dev/random.
PrivateDevices=true
# Deny the creation of writable and executable memory mappings.
MemoryDenyWriteExecute=true
[Install]
WantedBy=multi-user.target
EOF

echo "$0 - Starting bitcoind service"
sudo systemctl enable bitcoind.service
sudo systemctl start bitcoind.service

fi


sleep 1
echo "Onion service up and running: $(</var/lib/tor/torgap-opentimestamps/hostname)"

# Finished, exit script
exit 0
