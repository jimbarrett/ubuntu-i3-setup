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

# ---------------------------------------------------------------------------
# colors and tracking
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failures=()

# ---------------------------------------------------------------------------
# functions
# ---------------------------------------------------------------------------

msg() {
	printf "${GREEN}>> %s${NC}\n" "$1"
}

warn() {
	printf "${YELLOW}>> WARNING: %s${NC}\n" "$1"
}

error() {
	printf "${RED}>> ERROR: %s${NC}\n" "$1"
	exit 1
}

# run a setup step, log failures but don't exit
run_step() {
	local name="$1"
	shift
	if ! "$@"; then
		warn "$name failed."
		failures+=("$name")
	fi
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
	if ! curl -fsSL "$programs_url" > /tmp/i3-programs.csv; then
		warn "Failed to download package list."
		return 1
	fi
	sed -i '/^#/d' /tmp/i3-programs.csv

	total=$(wc -l < /tmp/i3-programs.csv)
	n=0

	while IFS=, read -r tag package description; do
		n=$((n + 1))
		description=$(echo "$description" | sed 's/^"\|"$//g')

		case "$tag" in
			"")
				msg "Installing $package ($n of $total)... $description"
				if ! DEBIAN_FRONTEND=noninteractive apt install -y -qq "$package"; then
					warn "Failed to install $package"
				fi
				;;
		esac
	done < /tmp/i3-programs.csv

	rm -f /tmp/i3-programs.csv
}

configure_lightdm() {
	msg "Configuring lightdm as default display manager..."

	if ! command -v lightdm >/dev/null 2>&1; then
		warn "lightdm is not installed, skipping configuration."
		return 1
	fi

	echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
	echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
	ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
	systemctl disable gdm3 2>/dev/null || true
	systemctl daemon-reload

	msg "lightdm configured."
}

install_nerd_font() {
	msg "Installing Hack Nerd Font..."

	font_dir="$userhome/.local/share/fonts/HackNerdFont"

	if [ -d "$font_dir" ] && [ "$(ls -1 "$font_dir"/*.ttf 2>/dev/null | wc -l)" -gt 0 ]; then
		msg "Hack Nerd Font already present, skipping download."
		return 0
	fi

	mkdir -p "$font_dir"

	# use a subshell so cd doesn't affect the rest of the script
	(
		cd /tmp
		if ! curl -fLO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip; then
			echo "Failed to download Hack Nerd Font."
			exit 1
		fi
		if ! unzip -o Hack.zip -d "$font_dir"; then
			echo "Failed to unzip Hack Nerd Font."
			exit 1
		fi
		rm -f Hack.zip
	)

	if [ $? -ne 0 ]; then
		warn "Hack Nerd Font installation failed."
		return 1
	fi

	chown -R "$username":"$username" "$font_dir"
}

install_nvm() {
	msg "Installing nvm..."

	export NVM_DIR="$userhome/.nvm"
	mkdir -p "$NVM_DIR"

	local install_script
	install_script=$(curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh)
	if [ -z "$install_script" ]; then
		warn "Failed to download nvm install script."
		return 1
	fi

	echo "$install_script" | sudo -u "$username" NVM_DIR="$NVM_DIR" bash
	if [ $? -ne 0 ]; then
		warn "nvm install script returned an error."
		return 1
	fi

	chown -R "$username":"$username" "$NVM_DIR"
}

install_go() {
	msg "Installing Go..."

	local go_version
	go_version=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)
	if [ -z "$go_version" ]; then
		warn "Failed to determine latest Go version."
		return 1
	fi

	if [ -d "/usr/local/go" ]; then
		current=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')
		if [ "$current" = "$go_version" ]; then
			msg "Go $go_version already installed, skipping."
			return 0
		fi
		rm -rf /usr/local/go
	fi

	# subshell for cd
	(
		cd /tmp
		if ! curl -fsSLO "https://go.dev/dl/${go_version}.linux-amd64.tar.gz"; then
			echo "Failed to download Go."
			exit 1
		fi
		tar -C /usr/local -xzf "${go_version}.linux-amd64.tar.gz"
		rm -f "${go_version}.linux-amd64.tar.gz"
	)

	if [ $? -ne 0 ]; then
		warn "Go installation failed."
		return 1
	fi

	if ! grep -q '/usr/local/go/bin' "$userhome/.profile" 2>/dev/null; then
		echo 'export PATH=$PATH:/usr/local/go/bin' >> "$userhome/.profile"
		chown "$username":"$username" "$userhome/.profile"
	fi
}

install_vscode() {
	msg "Installing VS Code..."

	if command -v code >/dev/null 2>&1; then
		msg "VS Code already installed, skipping."
		return 0
	fi

	if ! curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg; then
		warn "Failed to add Microsoft GPG key."
		return 1
	fi

	echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list

	if ! apt update -qq; then
		warn "Failed to update apt after adding VS Code repo."
		return 1
	fi

	if ! DEBIAN_FRONTEND=noninteractive apt install -y -qq code; then
		warn "Failed to install VS Code."
		return 1
	fi
}

install_starship() {
	msg "Installing Starship prompt..."

	if command -v starship >/dev/null 2>&1; then
		msg "Starship already installed, skipping."
		return 0
	fi

	if ! curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
		warn "Failed to install Starship."
		return 1
	fi
}

deploy_dotfiles() {
	msg "Deploying dotfiles..."

	local tmpdir
	tmpdir=$(mktemp -d)

	if ! git clone --depth 1 "$configs_repo" "$tmpdir/configs"; then
		warn "Failed to clone dotfiles repo."
		rm -rf "$tmpdir"
		return 1
	fi

	rm -rf "$tmpdir/configs/.git" "$tmpdir/configs/README.md" "$tmpdir/configs/LICENSE"
	cp -rfT "$tmpdir/configs" "$userhome"
	chmod +x "$userhome/.local/bin/i3blocks/"* 2>/dev/null || true
	chmod +x "$userhome/.xinitrc" 2>/dev/null || true
	mkdir -p "$userhome/.screenlayout"
	chown -R "$username":"$username" "$userhome/.config" "$userhome/.local" "$userhome/.Xresources" "$userhome/.xinitrc" "$userhome/.screenlayout"

	rm -rf "$tmpdir"
	msg "Dotfiles deployed."
}

configure_cursor() {
	msg "Configuring cursor size..."

	if ! grep -q "Xcursor.size" "$userhome/.Xresources" 2>/dev/null; then
		echo "Xcursor.size: 24" >> "$userhome/.Xresources"
	fi

	if ! grep -q "XCURSOR_SIZE" "$userhome/.profile" 2>/dev/null; then
		echo "export XCURSOR_SIZE=24" >> "$userhome/.profile"
	fi

	sudo -u "$username" gsettings set org.gnome.desktop.interface cursor-size 24 2>/dev/null || true

	chown "$username":"$username" "$userhome/.Xresources" "$userhome/.profile"
}

set_shell() {
	current_shell=$(getent passwd "$username" | cut -d: -f7)
	if [ "$current_shell" != "/usr/bin/zsh" ] && [ "$current_shell" != "/bin/zsh" ]; then
		msg "Setting default shell to zsh..."
		if ! chsh -s "$(which zsh)" "$username"; then
			warn "Failed to set zsh as default shell."
			return 1
		fi
	else
		msg "zsh is already the default shell."
	fi
}

disable_autorandr_service() {
	# autorandr's systemd service causes monitor flickering on thunderbolt docks
	# by repeatedly re-applying display profiles. we use manual layout switching instead.
	if systemctl list-unit-files autorandr.service >/dev/null 2>&1; then
		msg "Disabling autorandr systemd service..."
		systemctl disable autorandr.service 2>/dev/null || true
		systemctl stop autorandr.service 2>/dev/null || true
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

print_summary() {
	echo ""
	echo "======================================"

	if [ ${#failures[@]} -eq 0 ]; then
		printf "${GREEN}  Setup complete! No errors.${NC}\n"
	else
		printf "${YELLOW}  Setup complete with ${#failures[@]} failed step(s):${NC}\n"
		echo "======================================"
		for f in "${failures[@]}"; do
			printf "${RED}  - %s${NC}\n" "$f"
		done
	fi

	echo "======================================"
	echo ""
	echo "Reboot and select 'i3' from the"
	echo "lightdm session picker to get started."
	echo ""
	echo "  sudo reboot"
	echo ""
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# repos
configs_repo="https://github.com/jimbarrett/ubuntu-i3-configs.git"
programs_url="https://raw.githubusercontent.com/jimbarrett/ubuntu-i3-setup/main/programs.csv"

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
run_step "lightdm config"  configure_lightdm
run_step "dotfiles"        deploy_dotfiles
run_step "Hack Nerd Font"  install_nerd_font
run_step "nvm"             install_nvm
run_step "Go"              install_go
run_step "VS Code"         install_vscode
run_step "Starship prompt" install_starship
run_step "cursor config"   configure_cursor
run_step "set zsh shell"   set_shell
disable_autorandr_service
disable_system_beep
rebuild_font_cache

print_summary
