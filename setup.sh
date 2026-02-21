#!/bin/bash
# Ubuntu i3 Setup
# by Jim Barrett
# License: GNU GPLv3
#
# Installs and configures i3 window manager with gruvbox-dark theme
# on a fresh Ubuntu install.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jimbarrett/ubuntu-i3-setup/main/setup.sh | sudo bash

set -e

# repos
configs_repo="https://github.com/jimbarrett/ubuntu-i3-configs.git"
programs_url="https://raw.githubusercontent.com/jimbarrett/ubuntu-i3-setup/main/programs.csv"

# colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# functions
# ---------------------------------------------------------------------------

msg() {
	printf "${GREEN}>> %s${NC}\n" "$1"
}

warn() {
	printf "${YELLOW}>> %s${NC}\n" "$1"
}

error() {
	printf "${RED}ERROR: %s${NC}\n" "$1"
	exit 1
}

preflight() {
	[ "$(id -u)" -eq 0 ] || error "This script must be run as root (use sudo)."

	command -v lsb_release >/dev/null 2>&1 || error "lsb_release not found. Is this Ubuntu?"

	distro=$(lsb_release -si)
	[ "$distro" = "Ubuntu" ] || error "This script is designed for Ubuntu. Detected: $distro"

	msg "Ubuntu $(lsb_release -sr) detected."
}

get_username() {
	# if SUDO_USER is set, use that (the user who ran sudo)
	if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
		username="$SUDO_USER"
		msg "Configuring for user: $username"
	else
		echo "Enter the username to configure:"
		read -r username < /dev/tty
		id "$username" >/dev/null 2>&1 || error "User '$username' does not exist."
	fi

	userhome=$(eval echo "~$username")
	[ -d "$userhome" ] || error "Home directory $userhome does not exist."
}

system_update() {
	msg "Updating system packages..."
	apt update -qq
	DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq
}

install_packages() {
	msg "Downloading package list..."
	curl -fsSL "$programs_url" | sed '/^#/d' > /tmp/i3-programs.csv

	total=$(wc -l < /tmp/i3-programs.csv)
	n=0

	while IFS=, read -r tag package description; do
		n=$((n + 1))
		# strip quotes from description
		description=$(echo "$description" | sed 's/^"\|"$//g')

		case "$tag" in
			"")
				msg "Installing $package ($n of $total)... $package $description"
				DEBIAN_FRONTEND=noninteractive apt install -y -qq "$package" >/dev/null 2>&1 || warn "Failed to install $package"
				;;
		esac
	done < /tmp/i3-programs.csv

	rm -f /tmp/i3-programs.csv
}

configure_lightdm() {
	msg "Configuring lightdm as default display manager..."

	# preseed the selection to avoid interactive prompt
	echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

	# set default display manager
	echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

	# create the systemd symlink (this is the fix that dpkg-reconfigure misses)
	ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service

	# disable gdm3 if present
	systemctl disable gdm3 2>/dev/null || true

	systemctl daemon-reload

	msg "lightdm configured."
}

install_nerd_font() {
	msg "Installing Hack Nerd Font..."

	font_dir="$userhome/.local/share/fonts/HackNerdFont"
	# skip if already deployed via dotfiles
	if [ -d "$font_dir" ] && [ "$(ls -1 "$font_dir"/*.ttf 2>/dev/null | wc -l)" -gt 0 ]; then
		msg "Hack Nerd Font already present from dotfiles, skipping download."
		return
	fi

	mkdir -p "$font_dir"
	cd /tmp
	curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip
	unzip -o Hack.zip -d "$font_dir" >/dev/null 2>&1
	rm -f Hack.zip
	chown -R "$username":"$username" "$font_dir"
}

install_nvm() {
	msg "Installing nvm..."

	export NVM_DIR="$userhome/.nvm"
	mkdir -p "$NVM_DIR"
	curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | sudo -u "$username" bash >/dev/null 2>&1
	chown -R "$username":"$username" "$NVM_DIR"
}

install_go() {
	msg "Installing Go..."

	# get latest version
	go_version=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)

	if [ -d "/usr/local/go" ]; then
		current=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')
		if [ "$current" = "$go_version" ]; then
			msg "Go $go_version already installed, skipping."
			return
		fi
		rm -rf /usr/local/go
	fi

	cd /tmp
	curl -fsSLO "https://go.dev/dl/${go_version}.linux-amd64.tar.gz"
	tar -C /usr/local -xzf "${go_version}.linux-amd64.tar.gz"
	rm -f "${go_version}.linux-amd64.tar.gz"

	# add to path if not already there
	if ! grep -q '/usr/local/go/bin' "$userhome/.profile" 2>/dev/null; then
		echo 'export PATH=$PATH:/usr/local/go/bin' >> "$userhome/.profile"
		chown "$username":"$username" "$userhome/.profile"
	fi
}

install_vscode() {
	msg "Installing VS Code..."

	if command -v code >/dev/null 2>&1; then
		msg "VS Code already installed, skipping."
		return
	fi

	# add microsoft repo
	curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg
	echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list
	apt update -qq
	DEBIAN_FRONTEND=noninteractive apt install -y -qq code >/dev/null 2>&1
}

deploy_dotfiles() {
	msg "Deploying dotfiles..."

	tmpdir=$(mktemp -d)
	git clone --depth 1 "$configs_repo" "$tmpdir/configs" >/dev/null 2>&1

	# remove git artifacts before copying
	rm -rf "$tmpdir/configs/.git" "$tmpdir/configs/README.md" "$tmpdir/configs/LICENSE"

	# copy into home directory, preserving structure
	cp -rfT "$tmpdir/configs" "$userhome"

	# ensure i3blocks scripts are executable
	chmod +x "$userhome/.local/bin/i3blocks/"* 2>/dev/null || true
	chmod +x "$userhome/.xinitrc" 2>/dev/null || true

	chown -R "$username":"$username" "$userhome/.config" "$userhome/.local" "$userhome/.Xresources" "$userhome/.xinitrc"

	rm -rf "$tmpdir"

	msg "Dotfiles deployed."
}

configure_cursor() {
	msg "Configuring cursor size..."

	# .Xresources (should already be set from dotfiles, but ensure it)
	if ! grep -q "Xcursor.size" "$userhome/.Xresources" 2>/dev/null; then
		echo "Xcursor.size: 24" >> "$userhome/.Xresources"
	fi

	# environment variable in .profile
	if ! grep -q "XCURSOR_SIZE" "$userhome/.profile" 2>/dev/null; then
		echo "export XCURSOR_SIZE=24" >> "$userhome/.profile"
	fi

	# gsettings (for apps that read from dconf)
	sudo -u "$username" gsettings set org.gnome.desktop.interface cursor-size 24 2>/dev/null || true

	chown "$username":"$username" "$userhome/.Xresources" "$userhome/.profile"
}

set_shell() {
	current_shell=$(getent passwd "$username" | cut -d: -f7)
	if [ "$current_shell" != "/usr/bin/zsh" ]; then
		msg "Setting default shell to zsh..."
		chsh -s /usr/bin/zsh "$username"
	fi
}

disable_system_beep() {
	msg "Disabling system beep..."
	echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf
	rmmod pcspkr 2>/dev/null || true
}

rebuild_font_cache() {
	msg "Rebuilding font cache..."
	sudo -u "$username" fc-cache -fv >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

clear
echo "======================================"
echo "  Ubuntu i3 Setup"
echo "======================================"
echo ""
echo "This will install i3 with gruvbox-dark"
echo "theme and all supporting tools."
echo ""
echo "Ready to begin? (y/n)"

while true; do
	read -r answer < /dev/tty
	case $answer in
		[Yy]*) break ;;
		[Nn]*) error "User exited." ;;
		*) echo "Please enter y or n." ;;
	esac
done

preflight
get_username

msg "Starting installation..."

system_update
install_packages
configure_lightdm
deploy_dotfiles
install_nerd_font
install_nvm
install_go
install_vscode
configure_cursor
set_shell
disable_system_beep
rebuild_font_cache

echo ""
echo "======================================"
printf "${GREEN}  Setup complete!${NC}\n"
echo "======================================"
echo ""
echo "Reboot and select 'i3' from the"
echo "lightdm session picker to get started."
echo ""
echo "  sudo reboot"
echo ""
