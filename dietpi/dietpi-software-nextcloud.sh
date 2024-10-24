#!/bin/bash
{
	#////////////////////////////////////
	# DietPi Software
	#
	#////////////////////////////////////
	# Created by Daniel Knight / daniel.knight@dietpi.com / dietpi.com
	#
	#////////////////////////////////////
	#
	# Info:
	# - Location: /boot/dietpi/dietpi-software
	# - Installs "ready to run" software with optimisations unique to the device.
	# - Generates and uses /boot/dietpi/.installed listing installed software.
	USAGE='
Usage: dietpi-software [<command> [<software_id>...]]
Available commands:
  <empty>			Interactive menu to install or uninstall software
  install <software_id>...	Install each software given by space-separated list of IDs
  reinstall <software_id>...	Reinstall each software given by space-separated list of IDs
  uninstall <software_id>...	Uninstall each software given by space-separated list of IDs
  list [--machine-readable]	Print a list with IDs and info for all available software titles
  free				Print an unused software ID, free for a new software implementation
'	#////////////////////////////////////

	# Import DietPi-Globals ---------------------------------------------------------------
	. /boot/dietpi/func/dietpi-globals
	readonly G_PROGRAM_NAME='DietPi-Software'
	G_CHECK_ROOT_USER
	G_CHECK_ROOTFS_RW
	G_INIT
	# Import DietPi-Globals ---------------------------------------------------------------

	[[ $1 == 'list' && $2 == '--machine-readable' ]] && MACHINE_READABLE=1 || MACHINE_READABLE=

	#/////////////////////////////////////////////////////////////////////////////////////
	# Install states file
	#/////////////////////////////////////////////////////////////////////////////////////
	Write_InstallFileList()
	{
		# Update webserver stack meta install states
		aSOFTWARE_INSTALL_STATE[75]=0 aSOFTWARE_INSTALL_STATE[76]=0
		aSOFTWARE_INSTALL_STATE[78]=0 aSOFTWARE_INSTALL_STATE[79]=0
		aSOFTWARE_INSTALL_STATE[81]=0 aSOFTWARE_INSTALL_STATE[82]=0
		if (( ${aSOFTWARE_INSTALL_STATE[89]} == 2 ))
		then
			# Apache
			if (( ${aSOFTWARE_INSTALL_STATE[83]} == 2 ))
			then
				(( ${aSOFTWARE_INSTALL_STATE[87]} == 2 )) && aSOFTWARE_INSTALL_STATE[75]=2 # SQLite: LASP
				(( ${aSOFTWARE_INSTALL_STATE[88]} == 2 )) && aSOFTWARE_INSTALL_STATE[76]=2 # MariaDB: LAMP

			# Nginx
			elif (( ${aSOFTWARE_INSTALL_STATE[85]} == 2 ))
			then
				(( ${aSOFTWARE_INSTALL_STATE[87]} == 2 )) && aSOFTWARE_INSTALL_STATE[78]=2 # SQLite: LESP
				(( ${aSOFTWARE_INSTALL_STATE[88]} == 2 )) && aSOFTWARE_INSTALL_STATE[79]=2 # MariaDB: LEMP

			# Lighttpd
			elif (( ${aSOFTWARE_INSTALL_STATE[84]} == 2 ))
			then
				(( ${aSOFTWARE_INSTALL_STATE[87]} == 2 )) && aSOFTWARE_INSTALL_STATE[81]=2 # SQLite: LLSP
				(( ${aSOFTWARE_INSTALL_STATE[88]} == 2 )) && aSOFTWARE_INSTALL_STATE[82]=2 # MariaDB: LLMP
			fi
		fi

		# Save installed states
		local i install_states
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			# Don't save pending and uninstalled states (-1/0/1)
			if (( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 ))
			then
				install_states+="aSOFTWARE_INSTALL_STATE[$i]=2
"
			# Store DietPi-RAMlog and Dropbear uninstalled state as well, as it is initialised as installed matching our image defaults
			elif (( $i == 103 || $i == 104 ))
			then
				install_states+="aSOFTWARE_INSTALL_STATE[$i]=0
"
			fi
		done

		# Save logging choice
		install_states+="INDEX_LOGGING=$INDEX_LOGGING"

		echo "$install_states" > /boot/dietpi/.installed
	}

	Read_InstallFileList()
	{
		if [[ -f '/boot/dietpi/.installed' ]]
		then
			# shellcheck disable=SC1091
			if [[ $MACHINE_READABLE ]]
			then
				. /boot/dietpi/.installed
			else
				G_EXEC_DESC='Reading database' G_EXEC . /boot/dietpi/.installed
			fi
		else
			# Assure that the file exists to allow choice/preference selections on first run: https://github.com/MichaIng/DietPi/issues/5080
			>> /boot/dietpi/.installed
		fi
	}

	Check_Net_and_Time_sync()
	{
		# Check network connectivity and sync system clock
		G_CHECK_NET
		/boot/dietpi/func/run_ntpd
	}

	#/////////////////////////////////////////////////////////////////////////////////////
	# Installation system
	#/////////////////////////////////////////////////////////////////////////////////////
	# Flag to trigger Run_Installations()
	GOSTARTINSTALL=0

	# Flag to skip APT update in Run_Installations(), set by DietPi-Automation_Pre()
	SKIP_APT_UPDATE=0

	# Logging choice index
	INDEX_LOGGING=-1

	# Array to collect all installed services to be enabled after installs have finished
	aENABLE_SERVICES=()
	# Since no automated reboot is done anymore after installs, collect services to start manually, when not controlled by DietPi-Services
	aSTART_SERVICES=()

	# Global password for software installs
	GLOBAL_PW=
	Update_Global_Pw()
	{
		local encrypt=0

		# Read encrypted password
		if [[ -f '/var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin' ]]
		then
			if ! GLOBAL_PW=$(openssl enc -d -a -md sha256 -aes-256-cbc -iter 10000 -salt -pass pass:'DietPiRocks!' -in /var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin)
			then
				# Allow decryption without pbkdf2/"-iter 10000" and re-encrypt on dist-upgraded Buster systems
				encrypt=1
				# In case of error, assure empty password to fallback to default
				GLOBAL_PW=$(openssl enc -d -a -md sha256 -aes-256-cbc -salt -pass pass:'DietPiRocks!' -in /var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin) || GLOBAL_PW=
			fi

		# If encryption has not yet been done, do it now!
		else
			encrypt=1
			GLOBAL_PW=$(sed -n '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
			grep -q '^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=' /boot/dietpi.txt && G_EXEC sed -i '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/c\#AUTO_SETUP_GLOBAL_PASSWORD= # Password has been encrypted and saved to rootfs' /boot/dietpi.txt
		fi

		# Fallback
		if [[ ! $GLOBAL_PW ]]
		then
			encrypt=1
			GLOBAL_PW='dietpi'
			G_WHIP_MSG "[FAILED] Unable to obtain your global software password
\nThe following fallback password will be used:\n - $GLOBAL_PW
\nYou can change it via:\n - dietpi-config > Security Options > Change Passwords"
		fi

		# Encrypt
		# https://github.com/koalaman/shellcheck/issues/1009
		# shellcheck disable=SC2086
		[[ $encrypt == 1 ]] && openssl enc -e -a -md sha256 -aes-256-cbc -iter 10000 -salt -pass pass:'DietPiRocks!' -out /var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin <<< $GLOBAL_PW

		# Apply safe permissions
		chown 0:0 /var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin
		chmod 0600 /var/lib/dietpi/dietpi-software/.GLOBAL_PW.bin
	}

	# Total physical system RAM: Used to calculate percentage based value for software cache limits, e.g.: OPcache/APCu
	readonly RAM_PHYS=$(free -m | mawk '/^Mem:/{print $2;exit}')
	# Total RAM + swap space: Used to estimate whether the swap file size needs to be increased.
	readonly RAM_TOTAL=$(free -tm | mawk '/^Total:/{print $2;exit}')

	# Whether to restart Deluge web UI once, required on fresh installs for auto-connection to work, more precisely a little delay between daemon and web UI is required
	RESTART_DELUGE_WEB=0

	# PHP version
	case $G_DISTRO in
		5) PHP_VERSION='7.3';;
		6) PHP_VERSION='7.4';;
		*) PHP_VERSION='8.2';;
	esac

	# Available for [$software_id,$G_*] 2D array
	declare -A aSOFTWARE_AVAIL_G_HW_MODEL
	declare -A aSOFTWARE_AVAIL_G_HW_ARCH
	declare -A aSOFTWARE_AVAIL_G_DISTRO

	# ToDo: On RPi 4, the 64-bit kernel is now used by default, without "arm_64bit=1" set: https://forums.raspberrypi.com/viewtopic.php?p=2088935#p2088935
	# - We could set "arm_64bit=0", but for now lets assure that 32-bit software is installed and see how it goes. This enables general support for RPi with 64-bit kernel running 32-bit userland.
	# - Also set a little flag here for the "dietpi-software list" command to correctly show that a software title is disabled because of the userland architecture, not because of the kernel architecture.
	RPI_64KERNEL_32OS=
	[[ $G_HW_MODEL == [2-9] && $G_HW_ARCH == 3 && $(dpkg --print-architecture) == 'armhf' ]] && G_HW_ARCH=2 G_HW_ARCH_NAME='armv7l' RPI_64KERNEL_32OS='32-bit image'


	# Unmark software installs for automated installs, if user input is required
	Unmark_Unattended()
	{
		(( $G_INTERACTIVE )) && return

		for i in "${!aSOFTWARE_NAME[@]}"
		do
			if (( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 && ${aSOFTWARE_INTERACTIVE[$i]:-0} == 1 ))
			then
				aSOFTWARE_INSTALL_STATE[$i]=0
				G_DIETPI-NOTIFY 2 "${aSOFTWARE_NAME[$i]}: Install requires user input and cannot be automated."
				G_DIETPI-NOTIFY 1 "${aSOFTWARE_NAME[$i]}: Please run 'dietpi-software' to install manually."
			fi
		done
	}

	# Unmark all dependants of a software title
	# $1: software ID
	Unmark_Dependants()
	{
		aSOFTWARE_INSTALL_STATE[$1]=0
		local i
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			# NB: This does not work for dependencies given as "webserver", "desktop" or "browser". However, there are no conflicts among desktops and browser, and webservers only conflict with other webservers, hence obviously one is installed already which satisfies the dependency.
			[[ ${aSOFTWARE_INSTALL_STATE[$i]} == 1 && ${aSOFTWARE_DEPS[$i]} =~ (^|[[:blank:]])$1([[:blank:]]|$) ]] || continue
			aSOFTWARE_INSTALL_STATE[$i]=0
			[[ $dependants_text ]] || dependants_text='\n\nThe following dependants will be unmarked as well:'
			dependants_text+="\n\n - ${aSOFTWARE_NAME[$i]}: It depends on ${aSOFTWARE_NAME[$1]}."
			# Recursive call to unmark all dependants of this dependant
			Unmark_Dependants "$i"
		done
	}

	# Unmark conflicting software titles
	CONFLICTS_RESOLVED=0
	Unmark_Conflicts()
	{
		# Loop through marked software
		local i j unmarked_text dependants_text
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) || continue

			# Loop through installed or marked conflicts
			for j in ${aSOFTWARE_CONFLICTS[$i]}
			do
				(( ${aSOFTWARE_INSTALL_STATE[$j]} > 0 )) || continue

				# At least one conflict is installed or marked: Unmark software
				(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && { unmarked_text+="\n\n${aSOFTWARE_NAME[$i]} won't be installed, as it conflicts with:"; Unmark_Dependants "$i"; }

				# Unmark all marked conflicts
				if (( ${aSOFTWARE_INSTALL_STATE[$j]} == 1 ))
				then
					unmarked_text+="\n\n - ${aSOFTWARE_NAME[$j]}: It won't be installed either."
					Unmark_Dependants "$j"
				else
					unmarked_text+="\n\n - ${aSOFTWARE_NAME[$j]}: It is installed already."
				fi
			done
		done

		CONFLICTS_RESOLVED=1
		[[ $unmarked_text ]] || return 0

		# Conflicts have been unmarked: Inform user!
		G_WHIP_MSG "[WARNING] Conflicting installs have been detected!$unmarked_text$dependants_text"
	}

	Select_Webserver_Dependency()
	{
		# Check for existing webserver (Apache, Nginx, Lighttpd) installation
		# - Do no reinstalls, as those are currently too intrusive, overriding custom configs
		(( ${aSOFTWARE_INSTALL_STATE[83]} < 1 && ${aSOFTWARE_INSTALL_STATE[84]} < 1 && ${aSOFTWARE_INSTALL_STATE[85]} < 1 )) || return 1

		# Auto-select webserver if manually installed
		if dpkg-query -s 'apache2' &> /dev/null
		then
			SELECTED_WEBSERVER=83; return 0

		elif dpkg-query -s 'nginx-common' &> /dev/null
		then
			SELECTED_WEBSERVER=85; return 0

		elif dpkg-query -s 'lighttpd' &> /dev/null
		then
			SELECTED_WEBSERVER=84; return 0
		fi

		local dependant=$1 preference_index=$(sed -n '/^[[:blank:]]*AUTO_SETUP_WEB_SERVER_INDEX=/{s/^[^=]*=//p;q}' /boot/dietpi.txt) software_id
		# Preference index to software ID
		case $preference_index in
			-2) software_id=84;; # Lighttpd
			-1) software_id=85;; # Nginx
			*) software_id=83;; # Apache (default)
		esac

		G_WHIP_MENU_ARRAY=(

			"${aSOFTWARE_NAME[83]}" ": ${aSOFTWARE_DESC[83]}"
			"${aSOFTWARE_NAME[85]}" ": ${aSOFTWARE_DESC[85]}"
			"${aSOFTWARE_NAME[84]}" ": ${aSOFTWARE_DESC[84]}"
		)

		G_WHIP_DEFAULT_ITEM=${aSOFTWARE_NAME[$software_id]}
		G_WHIP_BUTTON_OK_TEXT='Confirm' G_WHIP_NOCANCEL=1
		G_WHIP_MENU "${aSOFTWARE_NAME[$dependant]} requires a webserver. Which one shall be installed?
\n- Apache: Feature-rich and popular. Recommended for beginners and users who are looking to follow Apache based guides.
\n- Nginx: Lightweight alternative to Apache. Nginx claims faster webserver performance compared to Apache.
\n- Lighttpd: Extremely lightweight and is generally considered to offer the \"best\" webserver performance for SBCs. Recommended for users who expect low webserver traffic.
\n- More info: https://dietpi.com/docs/software/webserver_stack/" || G_WHIP_RETURNED_VALUE=${aSOFTWARE_NAME[$software_id]}

		# Software name to ID and preference index
		if [[ $G_WHIP_RETURNED_VALUE == "${aSOFTWARE_NAME[83]}" ]]
		then
			SELECTED_WEBSERVER=83 preference_index=0

		elif [[ $G_WHIP_RETURNED_VALUE == "${aSOFTWARE_NAME[85]}" ]]
		then
			SELECTED_WEBSERVER=85 preference_index=-1

		elif [[ $G_WHIP_RETURNED_VALUE == "${aSOFTWARE_NAME[84]}" ]]
		then
			SELECTED_WEBSERVER=84 preference_index=-2
		fi

		G_CONFIG_INJECT 'AUTO_SETUP_WEB_SERVER_INDEX=' "AUTO_SETUP_WEB_SERVER_INDEX=$preference_index" /boot/dietpi.txt
		return 0
	}

	

	# $1: software ID
	Resolve_Dependencies()
	{
		# Loop through dependencies
		local i
		for i in ${aSOFTWARE_DEPS[$1]}
		do
			# Resolve webserver dependency based on install state and user preference
			if [[ $i == 'webserver' ]]
			then
				Select_Webserver_Dependency "$1" || continue
				i=$SELECTED_WEBSERVER
			fi

			# Skip if dependency is marked for install already
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && continue

			# Is it reinstalled or freshly installed?
			local re_installed='installed'
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 )) && re_installed='reinstalled'

			aSOFTWARE_INSTALL_STATE[$i]=1
			G_DIETPI-NOTIFY 2 "${aSOFTWARE_NAME[$i]} will be $re_installed"
			# Recursive call to resolve dependencies of this dependency
			Resolve_Dependencies "$i"
		done
	}

	# Work out which additional software we need to install
	# - We do reinstall most =2 marked software as well, just to be sure.
	Mark_Dependencies()
	{
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Checking for prerequisite software'

		# If OctoPrint and mjpg-streamer both are installed, OctoPrint is automatically configured to use mjpg-streamer. For the integrated time-lapse feature, FFmpeg is required.
		if (( ${aSOFTWARE_INSTALL_STATE[137]} > 0 && ${aSOFTWARE_INSTALL_STATE[153]} > 0 && ${aSOFTWARE_INSTALL_STATE[137]} + ${aSOFTWARE_INSTALL_STATE[153]} < 4 ))
		then
			aSOFTWARE_INSTALL_STATE[7]=1
			G_DIETPI-NOTIFY 2 "${aSOFTWARE_NAME[7]} will be installed"
		fi

		# Loop through marked software to resolve dependencies each
		local i
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) || continue
			Resolve_Dependencies "$i"
		done
	}


	# Usage:
	#	Download_Install 'https://file.com/file' [/path/to/target]
	#	dps_index=$software_id Download_Install 'conf_0' /etc/conf.conf
	# Optional input variables:
	#	fallback_url='http...'    = URL to use if e.g. grabbing URL from api.github.com fails
	#	dps_index=$software_id    = Download from DietPi GitHub repo based on software ID/index
	#	aDEPS=('pkg1' 'pkg2' ...) = Install APT dependency packages
	# NB: This does not support installs that require user input (e.g.: a whiptail prompt for deb installs)
	Download_Install()
	{
		# Verify input URL
		if [[ $1 ]]
		then
			local url=$1

		elif [[ $fallback_url ]]
		then
			G_DIETPI-NOTIFY 1 "Automatic latest ${aSOFTWARE_NAME[$software_id]} download URL detection failed."
			G_DIETPI-NOTIFY 1 "\"$fallback_url\" will be used as fallback, but a newer version might be available."
			G_DIETPI-NOTIFY 1 'Please report this at: https://github.com/MichaIng/DietPi/issues'
			local url=$fallback_url
		else
			G_DIETPI-NOTIFY 1 "An empty download URL was passed during ${aSOFTWARE_NAME[$software_id]} install. Please report this at: https://github.com/MichaIng/DietPi/issues"
			return 1
		fi

		local target=$2 # Target path
		local file=${url##*/} # Grab file name from URL

		# DietPi-Software conf/service mode
		# shellcheck disable=SC2154
		[[ $dps_index && ${aSOFTWARE_NAME[$dps_index]} ]] && url="https://raw.githubusercontent.com/$G_GITOWNER/DietPi/$G_GITBRANCH/.conf/dps_$dps_index/$url"

		G_EXEC cd "$G_WORKING_DIR" # Failsafe

		# Add decompressor to deps list if missing
		case $file in
			*'.xz'|*'.txz') command -v xz > /dev/null || aDEPS+=('xz-utils');;
			*'.bz2'|*'.tbz2') command -v bzip2 > /dev/null || aDEPS+=('bzip2');;
			*'.zip') command -v unzip > /dev/null || aDEPS+=('unzip');;
			*'.7z') command -v 7zr > /dev/null || aDEPS+=('p7zip');;
			*) :;;
		esac

		# Download file
		if [[ ${aDEPS[0]} ]]
		then
			# Check URL before starting background download, as a failure does not terminate the install
			# shellcheck disable=SC2154
			G_CHECK_URL "$url"

			# Download as background thread if dependencies are to be installed
			G_THREAD_START curl -sSfL "$url" -o "$file"
			# shellcheck disable=SC2086
			G_AGI "${aDEPS[@]}"
			aDEPS=()
			G_THREAD_WAIT
		else
			G_EXEC curl -sSfL "$url" -o "$file"
		fi

		unset -v fallback_url dps_index

		# Process downloaded file
		case $file in
			*'.gz') [[ $file == *'.tar.gz' ]] || { G_EXEC gzip -df "$file" && file=${file%.gz}; };;
			*'.xz') [[ $file == *'.tar.xz' ]] || { G_EXEC xz -df "$file" && file=${file%.xz}; };;
			*'.bz2') [[ $file == *'.tar.bz2' ]] || { G_EXEC bzip2 -df "$file" && file=${file%.bz2}; };;
			*) :;;
		esac
		if [[ $file == *'.deb' ]]
		then
			G_AGI "./$file"

		elif [[ $file == *'.zip' ]]
		then
			G_EXEC unzip -o "$file" ${target:+"-d$target"}

		elif [[ $file =~ \.(t?gz|t?xz|t?bz2|tar)$ ]]
		then
			G_EXEC tar xf "$file" ${target:+"--one-top-level=$target"}

		elif [[ $file == *'.7z' ]]
		then
			[[ $target && ! -d $target ]] && G_EXEC mkdir -p "$target" # Workaround for 7zr ignoring umask: https://github.com/MichaIng/DietPi/issues/4251
			G_EXEC 7zr x -y "$file" ${target:+"-o$target"}

		elif [[ $target && $target != "$file" ]]
		then
			# Pre-create target dir if given: $target can be a file name only, so assure it is a path containing a dir
			[[ $target == *'/'* && ! -d ${target%/*} ]] && G_EXEC mkdir -p "${target%/*}"
			G_EXEC mv "$file" "$target"
		else
			return
		fi

		[[ -f $file ]] && G_EXEC rm "$file"
	}

	Create_User()
	{
		# Parse input and mark as read-only to throw an error if given doubled
		local group_primary groups_supplementary home shell password user
		while (( $# ))
		do
			case $1 in
				'-g') shift; readonly group_primary=$1;; # Primary group is always pre-created and defaults to same name as user for new users
				'-G') shift; readonly groups_supplementary=$1;; # User is only added to supplementary groups that do exist
				'-d') shift; readonly home=$1;; # Home is never pre-created and defaults to "/nonexistent" which prevents login
				'-s') shift; readonly shell=$1;; # Shell defaults to "nologin" which prevents shell access on login even if home exists
				'-p') shift; readonly password=$1;; # Password is only set for new users while existing users' passwords stay untouched
				*) readonly user=$1;;
			esac
			shift
		done

		# Pre-create given primary group, as useradd and usermod fail if it does not exist
		[[ $group_primary ]] && ! getent group "$group_primary" > /dev/null && G_EXEC groupadd -r "$group_primary"

		# Only add to supplementary groups that do exist
		local group groups
		for group in ${groups_supplementary//,/ }
		do
			getent group "$group" > /dev/null && groups+=",$group"
		done
		groups=${groups#,}

		# Create user if missing, else modify it according to input
		if getent passwd "$user" > /dev/null
		then
			G_EXEC usermod ${group_primary:+-g "$group_primary"} ${groups:+-aG "$groups"} -d "${home:-/nonexistent}" -s "${shell:-$(command -v nologin)}" "$user"
		else
			local options='-rMU'
			[[ $group_primary ]] && options='-rMN'
			G_EXEC useradd "$options" ${group_primary:+-g "$group_primary"} ${groups:+-G "$groups"} -d "${home:-/nonexistent}" -s "${shell:-$(command -v nologin)}" "$user"
			[[ $password ]] && G_EXEC_DESC="Applying user password: \e[33m${password//?/*}\e[0m" G_EXEC eval "chpasswd <<< '$user:$password'"
		fi
	}

	# Start a service and wait for a default config file to be created.
	Create_Config()
	{
		local file=$1 service=$2 # Config file path and service name
		local timeout=${3:-25} # Optional [s]
		local output=$4 pid # Optional, if timeout is set, hence for startups which may take long so that showing some process becomes reasonable
		# shellcheck disable=SC2154
		local content=$CREATE_CONFIG_CONTENT stop=$CC_STOP # Optional required config file content and whether to stop service afterwards (!= 0)
		unset -v CREATE_CONFIG_CONTENT CC_STOP

		# If file exists already and contains required content, continue install
		[[ -f $file ]] && { [[ ! $content ]] || grep -q "$content" "$file"; } && return 0

		# Reload services
		G_EXEC systemctl daemon-reload

		# File does not exist or does not contain required content: Start service
		G_EXEC_DESC="Starting ${aSOFTWARE_NAME[$software_id]} to pre-create config file in max $timeout seconds" G_EXEC systemctl start "$service"

		# Print and follow output of the service startup
		[[ $output ]] && { journalctl -fn 0 -u "$service" & pid=$!; }

		# Wait for max $timeout seconds until config file has been created and required content added, if given
		local i=0
		until [[ -f $file ]] && { [[ ! $content ]] || grep -q "$content" "$file"; } || (( $i >= $timeout )) || ! systemctl -q is-active "$service"
		do
			((i++))
			[[ $output ]] || G_DIETPI-NOTIFY -2 "Waiting for ${aSOFTWARE_NAME[$software_id]} config file to be created ($i/$timeout)"
			G_SLEEP 1
		done

		# Stop journal prints
		[[ $output ]] && { kill "$pid"; wait "$pid"; } 2> /dev/null

		# Stop service
		if [[ $stop != 0 ]]
		then
			G_SLEEP 1
			G_EXEC_NOHALT=1 G_EXEC systemctl stop "$service"
			G_SLEEP 1
		fi

		# If file exists already and contains required content, continue install
		if [[ -f $file ]] && { [[ ! $content ]] || grep -q "$content" "$file"; }
		then
			G_DIETPI-NOTIFY 2 "${aSOFTWARE_NAME[$software_id]} config file got created after $i seconds"
			return 0
		fi

		G_DIETPI-NOTIFY 1 "Waiting for ${aSOFTWARE_NAME[$software_id]} config file failed, skipping pre-configuration"
		return 1
	}

	# Remove obsolete SysV service
	# $1: Service name
	# $2: If set, remove defaults file as well (optional)
	Remove_SysV()
	{
		G_DIETPI-NOTIFY 2 "Removing obsolete SysV $1 service"
		[[ -f '/etc/init.d/'$1 ]] && G_EXEC rm "/etc/init.d/$1"
		G_EXEC update-rc.d "$1" remove
		[[ $2 && -f '/etc/default/'$1 ]] && G_EXEC rm "/etc/default/$1"
	}

	# Run marked software installs
	Install_Software()
	{
		local software_id aDEPS=()

		# Configure iptables to use nf_tables or legacy API, depending on which is supported by kernel
		Configure_iptables()
		{
			local alt='nft'
			iptables-nft -L &> /dev/null || alt='legacy'
			G_EXEC update-alternatives --set iptables "/usr/sbin/iptables-$alt"
			G_EXEC update-alternatives --set ip6tables "/usr/sbin/ip6tables-$alt"
		}

		Enable_memory_cgroup()
		{
			if (( $G_HW_MODEL < 10 ))
			then
				grep -Eq '(^|[[:blank:]])cgroup_enable=memory([[:blank:]]|$)' /boot/cmdline.txt || G_EXEC sed -i '/root=/s/[[:blank:]]*$/ cgroup_enable=memory/' /boot/cmdline.txt

			elif [[ -f '/boot/boot.scr' ]] && grep -q 'docker_optimizations' /boot/boot.scr
			then
				# DietPi mainline U-Boot
				[[ -f '/boot/dietpiEnv.txt' ]] && G_CONFIG_INJECT 'docker_optimizations=' 'docker_optimizations=on' /boot/dietpiEnv.txt
				# Armbian
				[[ -f '/boot/armbianEnv.txt' ]] && G_CONFIG_INJECT 'docker_optimizations=' 'docker_optimizations=on' /boot/armbianEnv.txt
				# Radxa Zero
				[[ -f '/boot/uEnv.txt' ]] && G_CONFIG_INJECT 'docker_optimizations=' 'docker_optimizations=on' /boot/uEnv.txt
			fi
		}

		# $1: Software name, so config can be created and removed per-software
		Enable_IP_forwarding()
		{
			G_DIETPI-NOTIFY 2 'Enabling IP forwarding to allow access across network interfaces'
			echo -e 'net.ipv4.ip_forward=1\nnet.ipv6.conf.default.accept_ra=2\nnet.ipv6.conf.all.accept_ra=2\nnet.ipv6.conf.default.forwarding=1\nnet.ipv6.conf.all.forwarding=1' > "/etc/sysctl.d/dietpi-$1.conf"
			sysctl net.ipv4.ip_forward=1 net.ipv6.conf.default.accept_ra=2 net.ipv6.conf.all.accept_ra=2 net.ipv6.conf.default.forwarding=1 net.ipv6.conf.all.forwarding=1
		}

		To_Install()
		{
			(( ${aSOFTWARE_INSTALL_STATE[$1]} == 1 )) || return 1
			G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "Installing ${aSOFTWARE_NAME[$1]}: ${aSOFTWARE_DESC[$1]}"
			software_id=$1
			shift
			[[ $1 ]] || return 0
			[[ $(readlink -m "/etc/systemd/system/$1.service") == '/dev/null' ]] && G_EXEC systemctl unmask "$1"
			aENABLE_SERVICES+=("$@")
		}

	### ------------------------------------------- POSTGRESQL ---------------------- {}	

		if To_Install 194 postgresql # PostgreSQL
		then
			G_DIETPI-NOTIFY 2 'Preparing database directory at: /mnt/dietpi_userdata/postgresql'
			if [[ -d '/mnt/dietpi_userdata/postgresql' ]]; then

				G_DIETPI-NOTIFY 2 '/mnt/dietpi_userdata/postgresql exists, will migrate containing databases'

			else
				# Otherwise use possibly existent /var/lib/postgresql
				# - Remove possible dead symlinks/files:
				G_EXEC rm -f /mnt/dietpi_userdata/postgresql
				if [[ -d '/var/lib/postgresql' ]]; then

					G_DIETPI-NOTIFY 2 '/var/lib/postgresql exists, will migrate containing databases'
					# Failsafe: Move symlink target in case, otherwise readlink will resolve to dir
					G_EXEC mv "$(readlink -f '/var/lib/postgresql')" /mnt/dietpi_userdata/postgresql

				else

					G_EXEC mkdir /mnt/dietpi_userdata/postgresql

				fi

			fi

			G_EXEC rm -Rf /var/lib/postgresql
			G_EXEC ln -s /mnt/dietpi_userdata/postgresql /var/lib/postgresql

			G_AGI postgresql
			G_EXEC systemctl stop postgresql

			# Disable TCP/IP listener and assure that UNIX domain socket is enabled at expected path
			for i in /etc/postgresql/*/main/conf.d
			do
				[[ -d $i ]] || continue
				echo "# Disable TCP listener and assure that UNIX socket is enabled at expected path
# NB: Do not edit this file, instead override settings via e.g.: conf.d/99local.conf
listen_addresses = ''
unix_socket_directories = '/run/postgresql'" > "$i/00dietpi.conf"
			done
		fi
### ------------------------------------------- POSTGRESQL ---------------------- {end}


#### --------------------------- DietPi RAM LOG ------------------------------------------- {begin}

		if To_Install 103 dietpi-ramlog # DietPi-RAMlog
		then
			# Install persistent tmpfs
			local var_log_size=$(sed -n '/^[[:blank:]]*AUTO_SETUP_RAMLOG_MAXSIZE=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
			sed -i '/[[:blank:]]\/var\/log[[:blank:]]/d' /etc/fstab
			echo "tmpfs /var/log tmpfs size=${var_log_size:-50}M,noatime,lazytime,nodev,nosuid" >> /etc/fstab

			# Apply logging choice index
			[[ $INDEX_LOGGING == -[12] ]] || INDEX_LOGGING=-1

			# Sync logs to disk once
			local acommand=('/boot/dietpi/func/dietpi-ramlog' '1')
			systemctl -q is-active dietpi-ramlog && acommand=('systemctl' 'stop' 'dietpi-ramlog')
			G_EXEC_DESC='Storing /var/log metadata to disk' G_EXEC "${acommand[@]}"
			unset -v acommand

			# Cleanup mount point
			findmnt /var/log > /dev/null && G_EXEC_DESC='Unmounting /var/log' G_EXEC_NOHALT=1 G_EXEC umount -Rfl /var/log
			G_EXEC_DESC='Cleaning /var/log mount point' G_EXEC rm -Rf /var/log/{,.??,.[^.]}*

			# Start DietPi-RAMlog
			G_EXEC_DESC='Mounting tmpfs to /var/log' G_EXEC mount /var/log
			G_EXEC_DESC='Restoring metadata to /var/log tmpfs' G_EXEC systemctl start dietpi-ramlog
		fi
#### --------------------------- DietPi RAM LOG ------------------------------------------- {end}


#### --------------------------- LOGROTATE ------------------------------------------- {begin}

		if To_Install 101 # Logrotate
		then
			G_AGI logrotate
		fi
#### --------------------------- LOGROTATE ------------------------------------------- {end}

#### --------------------------- BEETS ------------------------------------------- {begin}

		if To_Install 190 # Beets
		then
			# Config: Preserve existing on reinstall
			[[ -d '/mnt/dietpi_userdata/beets' ]] || G_EXEC mkdir /mnt/dietpi_userdata/beets
			[[ -f '/mnt/dietpi_userdata/beets/config.yaml' ]] || echo -e 'directory: /mnt/dietpi_userdata/Music\nlibrary: /mnt/dietpi_userdata/beets/library.db' > /mnt/dietpi_userdata/beets/config.yaml

			# Allow dietpi user and audio group members to manage library
			[[ -f '/mnt/dietpi_userdata/beets/library.db' ]] || > /mnt/dietpi_userdata/beets/library.db
			[[ -f '/mnt/dietpi_userdata/beets/state.pickle' ]] || > /mnt/dietpi_userdata/beets/state.pickle
			# shellcheck disable=SC2015
			getent passwd dietpi > /dev/null && G_EXEC chown -R dietpi:audio /mnt/dietpi_userdata/beets || G_EXEC chgrp -R audio /mnt/dietpi_userdata/beets
			G_EXEC chmod -R g+w /mnt/dietpi_userdata/beets

			# Load global beets config in all interactive bash shells
			echo 'export BEETSDIR=/mnt/dietpi_userdata/beets' > /etc/bashrc.d/dietpi-beets.sh
			# shellcheck disable=SC1091
			. /etc/bashrc.d/dietpi-beets.sh

			# Install
			G_AGI beets
		fi
#### --------------------------- BEETS ------------------------------------------- {end}


#### --------------------------- RSYSLOG ------------------------------------------- {begin}

		if To_Install 102 rsyslog # Rsyslog
		then
			# Workaround for dpkg failure on 1st install if service is already running but APT not installed: https://github.com/MichaIng/DietPi/pull/2277/#issuecomment-441460925
			systemctl -q is-active rsyslog && G_EXEC systemctl stop rsyslog
			G_AGI rsyslog
			G_EXEC systemctl start rsyslog

			# Apply logging choice index
			grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || findmnt -t tmpfs -M /var/log > /dev/null || INDEX_LOGGING=-3
		fi
#### --------------------------- RSYSLOG ------------------------------------------- {end}


#### --------------------------- FFMPEG ------------------------------------------- {begin}
		if To_Install 7 # FFmpeg
		then
			# RPi: Enable hardware codecs
			(( $G_HW_MODEL > 9 )) || /boot/dietpi/func/dietpi-set_hardware rpi-codec 1

			G_AGI ffmpeg
		fi
#### --------------------------- FFMPEG ------------------------------------------- {end}

#### --------------------------- NODE.JS ------------------------------------------- {begin}
		if To_Install 9 # Node.js
		then
			# Deps: https://github.com/MichaIng/DietPi/issues/3614
			aDEPS=('libatomic1')

			# Download installer
			Download_Install 'https://raw.githubusercontent.com/MichaIng/nodejs-linux-installer/master/node-install.sh'
			G_EXEC chmod +x node-install.sh

			# ARMv6/RISC-V: Use unofficial builds to get the latest version: https://github.com/MichaIng/nodejs-linux-installer/pull/2, https://github.com/MichaIng/nodejs-linux-installer/commit/cd952fe
			local unofficial=()
			(( $G_HW_ARCH == 1 || $G_HW_ARCH == 11 )) && unofficial=('-u')
			G_EXEC_OUTPUT=1 G_EXEC ./node-install.sh "${unofficial[@]}"
			G_EXEC rm node-install.sh
		fi
#### --------------------------- NODE.JS ------------------------------------------- {end}



#### --------------------------- PYTHON 3 ------------------------------------------- {begin}

		if To_Install 130 # Python 3
		then
			# Workaround for pip v23
			>> /etc/pip.conf
			G_CONFIG_INJECT '\[global\]' '[global]' /etc/pip.conf
			G_CONFIG_INJECT 'break-system-packages[[:blank:]]*=' 'break-system-packages=true' /etc/pip.conf '\[global\]'

			# Disable cache
			G_CONFIG_INJECT 'no-cache-dir[[:blank:]]*=' 'no-cache-dir=true' /etc/pip.conf '\[global\]'

			# ARMv6/7: Add piwheels
			(( $G_HW_ARCH < 3 )) && G_CONFIG_INJECT 'extra-index-url[[:blank:]]*=' 'extra-index-url=https://www.piwheels.org/simple/' /etc/pip.conf '\[global\]'

			# Workaround for missing and failing numpy >=v1.21.5 build: https://github.com/piwheels/packages/issues/287#issuecomment-1036500818
			if (( $G_HW_ARCH < 3 && $G_DISTRO == 5 ))
			then
				G_EXEC eval 'echo "numpy<1.21.5; python_version=='\''3.7'\''" > /etc/pip-constraints.txt'
				G_CONFIG_INJECT '\[install\]' '[install]' /etc/pip.conf
				G_CONFIG_INJECT 'constraint[[:blank:]]*=[[:blank:]]*/etc/pip-constraints.txt' 'constraint=/etc/pip-constraints.txt' /etc/pip.conf '\[install\]'
			fi

			# Perform pip3 install (which includes setuptools and wheel modules)
			aDEPS=('python3-dev')
			Download_Install 'https://bootstrap.pypa.io/get-pip.py'
			G_EXEC_OUTPUT=1 G_EXEC python3 get-pip.py
			G_EXEC rm get-pip.py
		fi
#### --------------------------- PYTHON 3 ------------------------------------------- {end}


#### --------------------------- NFS KERNEL SERVER ------------------------------------------- {begin}

		if To_Install 109 nfs-kernel-server # NFS Server
		then
			G_AGI nfs-kernel-server
			G_EXEC systemctl stop nfs-kernel-server

			[[ -d '/etc/exports.d' ]] || G_EXEC mkdir /etc/exports.d
			[[ -f '/etc/exports.d/dietpi.exports' ]] || echo '/mnt/dietpi_userdata *(rw,async,no_root_squash,fsid=0,crossmnt,no_subtree_check)' > /etc/exports.d/dietpi.exports
		fi
#### --------------------------- NFS KERNEL SERVER ------------------------------------------- {end}


#### --------------------------- APACHE ------------------------------------------- {end}

		if To_Install 83 apache2 # Apache
		then
			# Pre-create a dummy port 80 vhost if it does not exist yet, so we can avoid overwriting it on reinstalls.
			if [[ ! -f '/etc/apache2/sites-available/000-default.conf' ]]
			then
				[[ -d '/etc/apache2/sites-available' ]] || G_EXEC mkdir -p /etc/apache2/sites-available
				cat << _EOF_ > /etc/apache2/sites-available/000-default.conf
# /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
	ServerName $(G_GET_NET ip)
</VirtualHost>
_EOF_
			# Otherwise assure that the webroot is changed, as all our install options depend on it.
			else
				G_EXEC sed -i 's|/var/www/html|/var/www|g' /etc/apache2/sites-available/000-default.conf
			fi

			local apackages=('apache2')
			# Install Certbot module, if Certbot was already installed
			(( ${aSOFTWARE_INSTALL_STATE[92]} == 2 )) && apackages+=('python3-certbot-apache')
			G_AGI "${apackages[@]}"
			G_EXEC systemctl stop apache2
			apachectl -M | grep -q 'cache_disk' || G_EXEC systemctl --no-reload disable --now apache-htcacheclean

			# Enable event MPM and headers module
			G_EXEC a2dismod -fq mpm_prefork
			G_EXEC a2enmod -q mpm_event headers

			# Disable obsolete default configs
			for i in 'charset' 'localized-error-pages' 'other-vhosts-access-log' 'security' 'serve-cgi-bin'
			do
				[[ -L /etc/apache2/conf-enabled/$i.conf ]] && G_EXEC a2disconf "$i"
			done

			# Config
			cat << _EOF_ > /etc/apache2/conf-available/dietpi.conf
# /etc/apache2/conf-available/dietpi.conf
# Default server name and webroot
ServerName $(G_GET_NET ip)
DocumentRoot /var/www

# Logging to: journalctl -u apache2
ErrorLog syslog:local7

# Allow unlimited Keep-Alive requests
MaxKeepAliveRequests 0

# MPM event configuration
# - Run a single process which does not expire
# - Limit request handler threads to 64
StartServers 1
ServerLimit 1
MaxConnectionsPerChild 0
ThreadsPerChild 64
ThreadLimit 64
MinSpareThreads 1
MaxSpareThreads 64
MaxRequestWorkers 64

# Minimize public info
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# Security headers
Header set X-Content-Type-Options "nosniff"
Header set X-Frame-Options "sameorigin"
Header set X-XSS-Protection "1; mode=block"
Header set X-Robots-Tag "noindex, nofollow"
Header set X-Permitted-Cross-Domain-Policies "none"
Header set Referrer-Policy "no-referrer"
_EOF_
			G_EXEC a2enconf dietpi

			# Force service to start after PHP-FPM
			G_EXEC mkdir -p /etc/systemd/system/apache2.service.d
			G_EXEC eval "echo -e '[Unit]\nAfter=php$PHP_VERSION-fpm.service' > /etc/systemd/system/apache2.service.d/dietpi.conf"

			# Webroot
			[[ -f '/var/www/html/index.html' && ! -f '/var/www/index.html' ]] && G_EXEC mv /var/www/html/index.html /var/www/
			[[ -d '/var/www/html' ]] && G_EXEC rmdir --ignore-fail-on-non-empty /var/www/html
		fi
#### --------------------------- APACHE ------------------------------------------- {begin}


#### --------------------------- NGINX ------------------------------------------- {begin}

		if To_Install 85 nginx # Nginx
		then
			local apackages=('nginx-light')
			# Install Certbot module, if Certbot was already installed
			(( ${aSOFTWARE_INSTALL_STATE[92]} == 2 )) && apackages+=('python3-certbot-nginx')
			G_AGI "${apackages[@]}"
			G_EXEC systemctl stop nginx

			# Custom configs, included by sites-enabled/default within server directive, while nginx/(conf.d|sites-enabled) is included by nginx.conf outside server directive
			[[ -d '/etc/nginx/sites-dietpi' ]] || G_EXEC mkdir /etc/nginx/sites-dietpi

			G_BACKUP_FP /etc/nginx/nginx.conf
			dps_index=$software_id Download_Install 'nginx.conf' /etc/nginx/nginx.conf
			# Adjust socket name to PHP version
			G_EXEC sed -i "s#/run/php/php.*-fpm.sock#/run/php/php$PHP_VERSION-fpm.sock#g" /etc/nginx/nginx.conf

			# CPU core count
			G_EXEC sed -i "/worker_processes/c\worker_processes $G_HW_CPU_CORES;" /etc/nginx/nginx.conf

			# Default site
			dps_index=$software_id Download_Install 'nginx.default' /etc/nginx/sites-available/default

			# Force service to start after PHP-FPM
			G_EXEC mkdir -p /etc/systemd/system/nginx.service.d
			G_EXEC eval "echo -e '[Unit]\nAfter=php$PHP_VERSION-fpm.service' > /etc/systemd/system/nginx.service.d/dietpi.conf"

			# Webroot
			[[ -f '/var/www/html/index.nginx-debian.html' ]] && G_EXEC mv /var/www/html/index.nginx-debian.html /var/www/
			[[ -d '/var/www/html' ]] && G_EXEC rmdir --ignore-fail-on-non-empty /var/www/html
		fi
#### --------------------------- NGINX ------------------------------------------- {end}


#### --------------------------- LIGHTTPD ------------------------------------------- {begin}
		if To_Install 84 lighttpd # Lighttpd
		then
			# Migrate existing configs in case of distro upgrades
			local deflate=() openssl=()
			if [[ -f '/etc/lighttpd/lighttpd.conf' ]]
			then
				# Buster: "create-mime.assign.pl" has been renamed to "create-mime.conf.pl"
				if grep -q 'create-mime\.assign\.pl' /etc/lighttpd/lighttpd.conf
				then
					G_DIETPI-NOTIFY 2 'Buster upgrade detected: Migrating from "create-mime.assign.pl" to "create-mime.conf.pl"'
					G_EXEC sed -i 's/create-mime\.assign\.pl/create-mime.conf.pl/' /etc/lighttpd/lighttpd.conf
				fi

				# Bullseye: mod_compress has been superseded by mod_deflate
				if (( $G_DISTRO > 5 )) && grep -q '^[[:blank:]]*"mod_compress",$' /etc/lighttpd/lighttpd.conf
				then
					G_DIETPI-NOTIFY 2 'Bullseye upgrade detected: Migrating from mod_compress to mod_deflate'
					G_EXEC sed -Ei '/^compress\..*=[[:blank:]]*["(].*[")]$/d' /etc/lighttpd/lighttpd.conf
					G_EXEC sed -i '/^[[:blank:]]*"mod_compress",$/d' /etc/lighttpd/lighttpd.conf
					deflate=('lighttpd-mod-deflate')
				fi

				# Bullseye: Install OpenSSL module if DietPi-LetsEncrypt was used
				if [[ $G_DISTRO -gt 5 && -f '/boot/dietpi/.dietpi-letsencrypt' ]]
				then
					G_DIETPI-NOTIFY 2 'DietPi-LetsEncrypt usage detected: Installing OpenSSL module'
					openssl=('lighttpd-mod-openssl')
					[[ -f '/etc/lighttpd/conf-available/50-dietpi-https.conf' ]] && ! grep -q '"mod_openssl"' /etc/lighttpd/conf-available/50-dietpi-https.conf && G_EXEC sed -i '1iserver.modules += ( "mod_openssl" )' /etc/lighttpd/conf-available/50-dietpi-https.conf
				fi

				# Bullseye: Remove obsolete socket version string from FPM module
				if [[ $G_DISTRO -gt 5 && -f '/etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf' ]] && grep -q 'php.\..-fpm\.sock' /etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf
				then
					G_DIETPI-NOTIFY 2 'Bullseye upgrade detected: Removing obsolete socket version string from FPM module'
					G_EXEC sed -i 's/php.\..-fpm\.sock/php-fpm.sock/' /etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf
				fi
			fi

			# perl is required for lighty-enable-mod, it has been degraded to recommends only with Buster.
			G_AGI lighttpd perl "${deflate[@]}" "${openssl[@]}"
			G_EXEC systemctl stop lighttpd

			Remove_SysV lighttpd

			# Enable mod_deflate, if flagged
			[[ ${deflate[0]} && ! -f '/etc/lighttpd/conf-enabled/20-deflate.conf' ]] && G_EXEC lighty-enable-mod deflate

			# Change webroot from /var/www/html to /var/www
			G_CONFIG_INJECT 'server.document-root' 'server.document-root = "/var/www"' /etc/lighttpd/lighttpd.conf
			if [[ -f '/var/www/html/index.lighttpd.html' ]]
			then
				G_EXEC mv /var/www/html/index.lighttpd.html /var/www/
				G_EXEC sed -i 's|/var/www/html|/var/www|' /etc/lighttpd/lighttpd.conf
			fi
			[[ -d '/var/www/html' ]] && G_EXEC rmdir --ignore-fail-on-non-empty /var/www/html

			# Configure PHP handler
			# - Buster: Create missing fastcgi-php-fpm module
			(( $G_DISTRO < 6 )) && cat << _EOF_ > /etc/lighttpd/conf-available/15-fastcgi-php-fpm.conf
# -*- depends: fastcgi -*-
# -*- conflicts: fastcgi-php -*-
# /usr/share/doc/lighttpd/fastcgi.txt.gz
# http://redmine.lighttpd.net/projects/lighttpd/wiki/Docs:ConfigurationOptions#mod_fastcgi-fastcgi

## Use PHP-FPM service for PHP via FastCGI
fastcgi.server += ( ".php" =>
	((
		"socket" => "/run/php/php$PHP_VERSION-fpm.sock",
		"broken-scriptfilename" => "enable"
	))
)
_EOF_
			# - Disable conflicting fastcgi-php module
			[[ -f '/etc/lighttpd/conf-enabled/15-fastcgi-php.conf' ]] && G_EXEC lighty-disable-mod fastcgi-php
			[[ -f '/etc/lighttpd/conf-enabled/15-fastcgi-php-fpm.conf' ]] || G_EXEC lighty-enable-mod fastcgi-php-fpm

			# Force service to start after PHP-FPM
			G_EXEC mkdir -p /etc/systemd/system/lighttpd.service.d
			G_EXEC eval "echo -e '[Unit]\nAfter=php$PHP_VERSION-fpm.service' > /etc/systemd/system/lighttpd.service.d/dietpi.conf"
		fi
#### --------------------------- LIGHTTPD ------------------------------------------- {end}



#### --------------------------- MARIA DB (formerly MYSQL) ------------------------------------------- {begin}

		if To_Install 88 mariadb # MariaDB
		then
			G_DIETPI-NOTIFY 2 'Preparing database directory at: /mnt/dietpi_userdata/mysql'
			if [[ -d '/mnt/dietpi_userdata/mysql' ]]; then

				G_DIETPI-NOTIFY 2 '/mnt/dietpi_userdata/mysql exists, will migrate containing databases'

			else
				# Otherwise use possibly existent /var/lib/mysql
				# - Remove possible dead symlinks/files:
				G_EXEC rm -f /mnt/dietpi_userdata/mysql
				if [[ -d '/var/lib/mysql' ]]; then

					G_DIETPI-NOTIFY 2 '/var/lib/mysql exists, will migrate containing databases'
					# Failsafe: Move symlink target in case, otherwise readlink will resolve to dir
					G_EXEC mv "$(readlink -f '/var/lib/mysql')" /mnt/dietpi_userdata/mysql

				else

					G_EXEC mkdir /mnt/dietpi_userdata/mysql

				fi

			fi

			G_EXEC rm -Rf /var/lib/mysql
			G_EXEC ln -s /mnt/dietpi_userdata/mysql /var/lib/mysql

			local apackages=('mariadb-server')
			# Install PHP module if PHP was already installed
			(( ${aSOFTWARE_INSTALL_STATE[89]} == 2 )) && apackages+=("php$PHP_VERSION-mysql")
			G_AGI "${apackages[@]}"
			G_EXEC systemctl stop mariadb

			Remove_SysV mysql 1

			# Assure correct owner in case the database dir got migrated from a different system: https://github.com/MichaIng/DietPi/issues/4721#issuecomment-917051930
			# - The group is correctly recursively fixed by the preinst script already.
			[[ -d '/mnt/dietpi_userdata/mysql/mysql' && $(stat -c '%U' /mnt/dietpi_userdata/mysql/mysql) != 'mysql' ]] && find /mnt/dietpi_userdata/mysql ! -user root ! -user mysql -exec chown mysql {} +

			# Force service to start before cron
			G_EXEC mkdir -p /etc/systemd/system/mariadb.service.d
			G_EXEC eval 'echo -e '\''[Unit]\nBefore=cron.service'\'' > /etc/systemd/system/mariadb.service.d/dietpi.conf'
		fi
#### --------------------------- MARIA DB (formerly MYSQL) ------------------------------------------- {end}


#### --------------------------- SQLite ------------------------------------------- {begin}

		if To_Install 87 # SQLite
		then
			local apackages=('sqlite3')
			# Install PHP module if PHP was already installed
			(( ${aSOFTWARE_INSTALL_STATE[89]} == 2 )) && apackages+=("php$PHP_VERSION-sqlite3")
			G_AGI "${apackages[@]}"
		fi
#### --------------------------- SQLite ------------------------------------------- {end}


#### --------------------------- REDIS ------------------------------------------- {begin}

		if To_Install 91 redis-server # Redis
		then
			local apackages=('redis-server')
			# Install PHP module if PHP was already installed
			(( ${aSOFTWARE_INSTALL_STATE[89]} == 2 )) && apackages+=("php$PHP_VERSION-redis")
			G_AGI "${apackages[@]}"
			G_EXEC systemctl stop redis-server

			# Enable Redis php module if installed
			command -v phpenmod > /dev/null && G_EXEC phpenmod redis

			# Disable file logging and enable syslog instead, which resolves reported startup issues in cases as well: https://github.com/MichaIng/DietPi/issues/3291
			G_CONFIG_INJECT 'loglevel[[:blank:]]' 'loglevel warning' /etc/redis/redis.conf
			G_CONFIG_INJECT 'logfile[[:blank:]]' 'logfile ""' /etc/redis/redis.conf
			G_CONFIG_INJECT 'syslog-enabled[[:blank:]]' 'syslog-enabled yes' /etc/redis/redis.conf
			G_CONFIG_INJECT 'always-show-logo[[:blank:]]' 'always-show-logo no' /etc/redis/redis.conf

			# Force service to start before cron
			G_EXEC mkdir -p /etc/systemd/system/redis-server.service.d
			G_EXEC eval 'echo -e '\''[Unit]\nBefore=cron.service'\'' > /etc/systemd/system/redis-server.service.d/dietpi.conf'
		fi
#### --------------------------- REDIS ------------------------------------------- {end}


#### --------------------------- PHP ------------------------------------------- {begin}


		if To_Install 89 # PHP
		then
			# Base PHP modules
			# - Webserver: PHP-FPM
			if (( ${aSOFTWARE_INSTALL_STATE[83]} > 0 || ${aSOFTWARE_INSTALL_STATE[84]} > 0 || ${aSOFTWARE_INSTALL_STATE[85]} > 0 ))
			then
				local apackages=("php$PHP_VERSION-fpm")
				aENABLE_SERVICES+=("php$PHP_VERSION-fpm")

			# - No webserver: CLI usage only (php binary)
			else
				local apackages=("php$PHP_VERSION-cli")
			fi

			# Additional PHP modules, commonly used by most web applications
			apackages+=("php$PHP_VERSION-apcu" "php$PHP_VERSION-curl" "php$PHP_VERSION-gd" "php$PHP_VERSION-mbstring" "php$PHP_VERSION-xml" "php$PHP_VERSION-zip")

			# MySQL/MariaDB PHP module
			(( ${aSOFTWARE_INSTALL_STATE[88]} > 0 )) && apackages+=("php$PHP_VERSION-mysql")

			# SQLite PHP module
			(( ${aSOFTWARE_INSTALL_STATE[87]} > 0 )) && apackages+=("php$PHP_VERSION-sqlite3")

			# Redis PHP module
			(( ${aSOFTWARE_INSTALL_STATE[91]} > 0 )) && apackages+=("php$PHP_VERSION-redis")

			G_AGI "${apackages[@]}"
			systemctl -q is-active "php$PHP_VERSION-fpm" && G_EXEC systemctl stop "php$PHP_VERSION-fpm"

			# Assure that mod_php is purged in favour of PHP-FPM
			G_AGP 'libapache2-mod-php*'
			G_EXEC rm -Rf /{etc/php,var/lib/php/modules}/*/apache2

			# PHP-FPM
			if (( ${aSOFTWARE_INSTALL_STATE[83]} > 0 || ${aSOFTWARE_INSTALL_STATE[84]} > 0 || ${aSOFTWARE_INSTALL_STATE[85]} > 0 ))
			then
				# Optimisations based on total cores
				G_CONFIG_INJECT 'pm.max_children[[:blank:]=]' "pm.max_children = $(( $G_HW_CPU_CORES * 3 ))" "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
				G_CONFIG_INJECT 'pm.start_servers[[:blank:]=]' "pm.start_servers = $G_HW_CPU_CORES" "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
				G_CONFIG_INJECT 'pm.min_spare_servers[[:blank:]=]' "pm.min_spare_servers = $G_HW_CPU_CORES" "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
				G_CONFIG_INJECT 'pm.max_spare_servers[[:blank:]=]' "pm.max_spare_servers = $G_HW_CPU_CORES" "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
				# Set static PATH, not passed by Lighttpd and Nginx by default but required by some web applications: https://github.com/MichaIng/DietPi/issues/5161#issuecomment-1013381362
				G_CONFIG_INJECT 'env\[PATH\][[:blank:]=]' 'env[PATH] = /usr/local/bin:/usr/bin:/bin' "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"

				# Force service to start after database servers
				G_EXEC mkdir -p "/etc/systemd/system/php$PHP_VERSION-fpm.service.d"
				G_EXEC eval "echo -e '[Unit]\nAfter=redis-server.service mariadb.service postgresql.service' > '/etc/systemd/system/php$PHP_VERSION-fpm.service.d/dietpi.conf'"
			fi

			# We create our own PHP mod to add DietPi specific configs.
			target_php_ini="/etc/php/$PHP_VERSION/mods-available/dietpi.ini"
			echo -e '; DietPi PHP settings\n; priority=97' > "$target_php_ini"

			# Session files need to be outside of /tmp and /var/tmp due to PrivateTmp=true, else phpsessionclean.service cannot clean sessions
			G_EXEC mkdir -p /run/php_sessions
			G_EXEC chmod 1733 /run/php_sessions
			echo -e '# Pre-create PHP sessions dir\nd /run/php_sessions 1733' > /etc/tmpfiles.d/dietpi-php_sessions.conf
			G_CONFIG_INJECT 'session.save_path[[:blank:]=]' 'session.save_path="/run/php_sessions"' "$target_php_ini"

			# File uploads: https://github.com/MichaIng/DietPi/issues/546
			# - This is especially relevant for cloud software like ownCloud/Nextcloud.
			# - Generally we want to hold tmp upload files in RAM to reduce disk (especially SD card) writes for performance and disk wear reasons.
			# - By default only max 2 MiB file uploads are allowed, hold in /tmp tmpfs, which is safe but not usable for usual cloud usage.
			# - ownCloud/Nextcloud do/did override this limit to 512 MiB, a reasonable limit which can usually still be hold in RAM without issues.
			# - Low RAM devices (RPi1 256 MiB model) require a swap file for this, however, it is still better to cause disk writes through swap file during large file uploads only, then doing this for each and every uploaded file.
			# - When larger file uploads are required, it depends on the system total RAM, rootfs disk and available external drives if/where to move tmp file uploads, resize or move swap file. This should be then left to user.
			G_CONFIG_INJECT 'upload_tmp_dir[[:blank:]=]' 'upload_tmp_dir="/tmp"' "$target_php_ini"
			G_CONFIG_INJECT 'upload_max_filesize[[:blank:]=]' 'upload_max_filesize=512M' "$target_php_ini"
			G_CONFIG_INJECT 'post_max_size[[:blank:]=]' 'post_max_size=512M' "$target_php_ini"
			# - Nginx: https://github.com/MichaIng/DietPi/issues/546 => https://github.com/MichaIng/DietPi/blob/dev/.conf/dps_85/nginx.conf

			# Cache settings
			local cache_size=$(( $RAM_PHYS / 30 ))
			(( $cache_size < 16 )) && cache_size=16
			# - OPcache
			G_CONFIG_INJECT 'opcache.memory_consumption[[:blank:]=]' "opcache.memory_consumption=$cache_size" "$target_php_ini"
			G_CONFIG_INJECT 'opcache.revalidate_freq[[:blank:]=]' 'opcache.revalidate_freq=60' "$target_php_ini" # 1 minute
			# - APCu
			G_CONFIG_INJECT 'apc.shm_size[[:blank:]=]' "apc.shm_size=$(( $cache_size / 2 ))M" "$target_php_ini"
			G_CONFIG_INJECT 'apc.ttl[[:blank:]=]' 'apc.ttl=259200' "$target_php_ini" # 3 days

			# Enable all available PHP modules
			local amodules=()
			mapfile -t amodules < <(find "/etc/php/$PHP_VERSION/mods-available" -type f -name '*.ini' -printf '%f\n')
			G_EXEC phpenmod "${amodules[@]%.ini}"
			unset -v amodules

			# Apache: Enable PHP-FPM
			command -v a2enconf > /dev/null && { G_EXEC a2enmod proxy_fcgi setenvif; G_EXEC a2enconf "php$PHP_VERSION-fpm"; }
		fi
#### --------------------------- PHP ------------------------------------------- {end}

#### --------------------------- PHP COMPOSER ------------------------------------------- {begin}
		if To_Install 34 # PHP Composer
		then
			G_EXEC curl -sSfL 'https://getcomposer.org/composer-stable.phar' -o /usr/local/bin/composer
			G_EXEC chmod +x /usr/local/bin/composer
		fi
#### --------------------------- PHP COMPOSER ------------------------------------------- {end}



#### --------------------------- PHP MY ADMIN ------------------------------------------- {begin}

		if To_Install 90 # phpMyAdmin
		then
			# Install required PHP modules: https://docs.phpmyadmin.net/en/latest/require.html#php
			# - Add JSON module for PHP7, as it does not exist (embedded in core package) on PHP8
			local json=()
			[[ $PHP_VERSION == 8* ]] || json=("php$PHP_VERSION-json")
			G_AGI "php$PHP_VERSION"-{curl,gd,mbstring,xml,zip} "${json[@]}"

			# Quick install: https://docs.phpmyadmin.net/en/latest/setup.html#quick-install
			# - Get latest version name
			local version=$(curl -sSfL 'https://api.github.com/repos/phpmyadmin/phpmyadmin/releases' | mawk -F\" '/^ *"name": "/ && $4!~/rc/ {print $4}' | sort -rV | head -1)
			[[ $version ]] || { version='5.2.1'; G_DIETPI-NOTIFY 1 "Automatic latest ${aSOFTWARE_NAME[$software_id]} version detection failed. Version \"$version\" will be installed as fallback, but a newer version might be available. Please report this at: https://github.com/MichaIng/DietPi/issues"; }
			Download_Install "https://files.phpmyadmin.net/phpMyAdmin/$version/phpMyAdmin-$version-english.tar.xz"
			# - Reinstall: Clean install but preserve existing config file
			[[ -f '/var/www/phpmyadmin/config.inc.php' ]] && G_EXEC mv /var/www/phpmyadmin/config.inc.php "phpMyAdmin-$version-english/"
			G_EXEC rm -Rf /var/www/phpmyadmin # Include pre-v6.27 symlink: https://github.com/MichaIng/DietPi/issues/3304
			# - Remove GUI setup: https://docs.phpmyadmin.net/en/latest/setup.html#securing-your-phpmyadmin-installation
			G_EXEC rm -R "phpMyAdmin-$version-english/setup"
			# - Move new instance in place
			G_EXEC mv "phpMyAdmin-$version-english" /var/www/phpmyadmin

			# Enable required PHP modules: https://docs.phpmyadmin.net/en/latest/require.html#php
			G_EXEC phpenmod ctype curl gd mbstring xml zip "${json[@]##*-}"


			# Install and enable webserver config
			# - Apache
			if (( ${aSOFTWARE_INSTALL_STATE[83]} > 0 ))
			then
				dps_index=$software_id Download_Install 'apache.phpmyadmin.conf' /etc/apache2/sites-available/dietpi-phpmyadmin.conf
				G_EXEC a2ensite dietpi-phpmyadmin

			# - Lighttpd
			elif (( ${aSOFTWARE_INSTALL_STATE[84]} > 0 ))
			then
				dps_index=$software_id Download_Install 'lighttpd.phpmyadmin.conf' /etc/lighttpd/conf-available/98-dietpi-phpmyadmin.conf
				G_EXEC_POST_FUNC(){ [[ $exit_code == 2 ]] && exit_code=0; } # Do not fail if modules are enabled already
				G_EXEC lighty-enable-mod dietpi-phpmyadmin

			# - Nginx
			elif (( ${aSOFTWARE_INSTALL_STATE[85]} > 0 ))
			then
				dps_index=$software_id Download_Install 'nginx.phpmyadmin.conf' /etc/apache2/sites-dietpi/dietpi-phpmyadmin.conf
			fi

			# Copy default config in place and adjust, if not already existent
			if [[ ! -f '/var/www/phpmyadmin/config.inc.php' ]]
			then
				G_EXEC cp -a /var/www/phpmyadmin/config.sample.inc.php /var/www/phpmyadmin/config.inc.php
				GCI_PASSWORD=1 G_CONFIG_INJECT "\\\$cfg\\['blowfish_secret'][[:blank:]]*=" "\$cfg['blowfish_secret'] = '$(openssl rand -base64 32)';" /var/www/phpmyadmin/config.inc.php
			fi

			# Create MariaDB database and user
			if [[ -d '/mnt/dietpi_userdata/mysql/phpmyadmin' ]]
			then
				G_DIETPI-NOTIFY 2 'phpMyAdmin MariaDB database found, will NOT overwrite.'
			else
				/boot/dietpi/func/create_mysql_db phpmyadmin phpmyadmin "$GLOBAL_PW"
				mysql phpmyadmin < /var/www/phpmyadmin/sql/create_tables.sql
				# Since "root" user cannot be used for login (unix_socket authentication), grant full admin privileges to "phpmyadmin"
				mysql -e 'grant all privileges on *.* to phpmyadmin@localhost with grant option;'
			fi

			# Pre-create TempDir: https://docs.phpmyadmin.net/en/latest/config.html#cfg_TempDir
			[[ -d '/var/www/phpmyadmin/tmp' ]] || G_EXEC mkdir /var/www/phpmyadmin/tmp
			G_EXEC chown www-data:root /var/www/phpmyadmin/tmp
			G_EXEC chmod 700 /var/www/phpmyadmin/tmp
		fi
#### --------------------------- PHP MY ADMIN ------------------------------------------- {end}




#### --------------------------- NEXTCLOUD ------------------------------------------- {begin}



		if To_Install 114 # Nextcloud
		then
			aDEPS=("php$PHP_VERSION-intl") # https://docs.nextcloud.com/server/stable/admin_manual/installation/source_installation.html#prerequisites-for-manual-installation

			if [[ -f '/var/www/nextcloud/occ' ]]
			then
				G_DIETPI-NOTIFY 2 'Existing Nextcloud installation found, will NOT overwrite...'
			else
				local datadir=$(sed -n '/^[[:blank:]]*SOFTWARE_NEXTCLOUD_DATADIR=/{s/^[^=]*=//;s|/$||;p;q}' /boot/dietpi.txt)
				[[ $datadir ]] || datadir='/mnt/dietpi_userdata/nextcloud_data'
				if [[ -f $datadir/dietpi-nextcloud-installation-backup/occ ]]
				then
					G_DIETPI-NOTIFY 2 'Nextcloud installation backup found, starting recovery...'
					G_EXEC cp -a "$datadir/dietpi-nextcloud-installation-backup/." /var/www/nextcloud/
					# Correct config.php data directory entry, in case it changed due to server migration:
					G_CONFIG_INJECT "'datadirectory'" "'datadirectory' => '$datadir'," /var/www/nextcloud/config/config.php "'dbtype'"
				else
					local version='latest'
					# Nextcloud 24 doesn't support PHP7.3 anymore: https://github.com/nextcloud/server/pull/29286
					if (( $G_DISTRO < 6 ))
					then
						G_DIETPI-NOTIFY 2 'Downloading latest Nextcloud 23, since Nextcloud 24 does not support PHP7.3 anymore'
						version='latest-23'

					# Nextcloud 26 doesn't support PHP7.4 anymore: https://github.com/nextcloud/server/pull/34997
					elif (( $G_DISTRO < 7 ))
					then
						G_DIETPI-NOTIFY 2 'Downloading latest Nextcloud 25, since Nextcloud 26 does not support PHP7.4 anymore'
						version='latest-25'
					fi
					Download_Install "https://download.nextcloud.com/server/releases/$version.tar.bz2" /var/www
				fi
			fi

			# Bookworm: Patch for PHP 8.2 support, which works quite well: https://github.com/nextcloud/server/issues/32595#issuecomment-1387559520
			if (( $G_DISTRO > 6 )) && grep -q '>= 80200' /var/www/nextcloud/lib/versioncheck.php
			then
				G_WHIP_MSG '[WARNING] Patching Nextcloud to support PHP 8.2 for Bookworm
\nNextcloud 25 does not support PHP 8.2, but it does work quite well:
- https://github.com/nextcloud/server/issues/32595#issuecomment-1387559520
\nWe are patching the PHP version check, but this has two implications:
- You will see an integrity check error on Nextcloud admin panel.
- You will need to redo the patch after Nextcloud updates to future 25.x versions:
# sed -i '\''s/>= 80200/>= 80300/'\'' /var/www/nextcloud/lib/versioncheck.php
\nWe recommend to update to Nextcloud 26 as fast as possible to get official PHP 8.2 support.'
				G_EXEC sed -i 's/>= 80200/>= 80300/' /var/www/nextcloud/lib/versioncheck.php
			fi

			[[ ${aDEPS[0]} ]] && { G_DIETPI-NOTIFY 2 'Installing required PHP modules'; G_AGI "${aDEPS[@]}"; aDEPS=(); }

			G_DIETPI-NOTIFY 2 'Enabling required PHP modules'
			# - Add JSON module for PHP7, as it does not exist (embedded in core package) on PHP8
			local json=()
			[[ $PHP_VERSION == 8* ]] || json=('json')
			G_EXEC phpenmod ctype curl dom gd intl mbstring pdo_mysql posix simplexml xmlreader xmlwriter zip fileinfo opcache apcu redis exif "${json[@]}"

			G_DIETPI-NOTIFY 2 'Apply PHP override settings for Nextcloud.' # https://docs.nextcloud.com/server/stable/admin_manual/installation/server_tuning.html#enable-php-opcache
			local memory_consumption=$(sed -n '/^[[:blank:]]*opcache.memory_consumption=/{s/^[^=]*=//p;q}' "/etc/php/$PHP_VERSION/mods-available/dietpi.ini")
			(( $memory_consumption < 64 )) && memory_consumption='\nopcache.memory_consumption=64' || memory_consumption=
			echo -e "; Nextcloud PHP settings\n; priority=98\nmemory_limit=512M$memory_consumption\nopcache.revalidate_freq=5\napc.enable_cli=1" > "/etc/php/$PHP_VERSION/mods-available/dietpi-nextcloud.ini"
			G_EXEC phpenmod dietpi-nextcloud

			if (( ${aSOFTWARE_INSTALL_STATE[83]} > 0 )); then

				G_DIETPI-NOTIFY 2 'Apache webserver found, enabling Nextcloud specific configuration.' # https://docs.nextcloud.com/server/stable/admin_manual/installation/source_installation.html#apache-web-server-configuration
				a2enmod rewrite headers env dir mime 1> /dev/null
				local nextcloud_conf='/etc/apache2/sites-available/dietpi-nextcloud.conf'
				if [[ -f $nextcloud_conf ]]; then

					nextcloud_conf+='.dietpi-new'
					G_WHIP_MSG "Existing Nextcloud Apache configuration found, will preserve the old one and save the new one for review and comparison to: $nextcloud_conf"

				fi
				dps_index=$software_id Download_Install 'apache.nextcloud.conf' "$nextcloud_conf"
				a2ensite dietpi-nextcloud 1> /dev/null
				# Cal/CardDAV redirects to Nextcloud DAV endpoint
				if [[ ! -f '/etc/apache2/conf-available/dietpi-dav_redirect.conf' ]]; then

					echo '# Redirect Cal/CardDAV requests to Nextcloud endpoint:
Redirect 301 /.well-known/carddav /nextcloud/remote.php/dav
Redirect 301 /.well-known/caldav  /nextcloud/remote.php/dav' > /etc/apache2/conf-available/dietpi-dav_redirect.conf
					a2enconf dietpi-dav_redirect

				fi

			elif (( ${aSOFTWARE_INSTALL_STATE[84]} > 0 )); then

				G_DIETPI-NOTIFY 2 'Lighttpd webserver found, enabling Nextcloud specific configuration.'

				# Enable required modules
				G_CONFIG_INJECT '"mod_access",' '	"mod_access",' /etc/lighttpd/lighttpd.conf '"mod_.+",'
				G_CONFIG_INJECT '"mod_setenv",' '	"mod_setenv",' /etc/lighttpd/lighttpd.conf '"mod_.+",'

				# Move Nextcloud configuration file in place and activate it
				nextcloud_conf='/etc/lighttpd/conf-available/99-dietpi-nextcloud.conf'
				if [[ -f $nextcloud_conf ]]; then

					nextcloud_conf+='.dietpi-new'
					G_WHIP_MSG "Existing Nextcloud Lighttpd configuration found, will preserve the old one and save the new one for review and comparison to: $nextcloud_conf"

				fi
				dps_index=$software_id Download_Install 'lighttpd.nextcloud.conf' "$nextcloud_conf"
				G_EXEC_POST_FUNC(){ [[ $exit_code == 2 ]] && exit_code=0; } # Do not fail if modules are enabled already
				G_EXEC lighty-enable-mod rewrite dietpi-nextcloud

				# Cal/CardDAV redirects to Nextcloud DAV endpoint
				if [[ ! -f '/etc/lighttpd/conf-enabled/99-dietpi-dav_redirect.conf' ]]; then

					echo '# Redirect Cal/CardDAV requests to Nextcloud endpoint:
url.redirect += (
	"^/.well-known/caldav"  => "/nextcloud/remote.php/dav",
	"^/.well-known/carddav" => "/nextcloud/remote.php/dav"
)' > /etc/lighttpd/conf-available/99-dietpi-dav_redirect.conf
					G_EXEC_POST_FUNC(){ [[ $exit_code == 2 ]] && exit_code=0; } # Do not fail if modules are enabled already
					G_EXEC lighty-enable-mod dietpi-dav_redirect

				fi

			elif (( ${aSOFTWARE_INSTALL_STATE[85]} > 0 )); then

				G_DIETPI-NOTIFY 2 'Nginx webserver found, enabling Nextcloud specific configuration.' # https://docs.nextcloud.com/server/stable/admin_manual/installation/nginx.html
				local nextcloud_conf='/etc/nginx/sites-dietpi/dietpi-nextcloud.conf'
				if [[ -f $nextcloud_conf ]]; then

					nextcloud_conf+='.dietpi-new'
					G_WHIP_MSG "Existing Nextcloud Nginx configuration found, will preserve the old one and save the new one for review and comparison to: $nextcloud_conf"

				fi
				dps_index=$software_id Download_Install 'nginx.nextcloud.conf' "$nextcloud_conf"

				# Cal/CardDAV redirects to Nextcloud DAV endpoint
				if [[ ! -f '/etc/nginx/sites-dietpi/dietpi-dav_redirect.conf' ]]; then

					echo '# Redirect Cal/CardDAV requests to Nextcloud endpoint:
location = /.well-known/carddav { return 301 /nextcloud/remote.php/dav/; }
location = /.well-known/caldav  { return 301 /nextcloud/remote.php/dav/; }' > /etc/nginx/sites-dietpi/dietpi-dav_redirect.conf

				fi

			fi

			# Start MariaDB and Redis (for reinstalls) for database creation and ncc command
			G_EXEC systemctl restart mariadb
			G_EXEC systemctl restart redis-server

			# Initially add occ command shortcut, will be added as alias by /etc/bashrc.d/dietpi.bash if occ file exist:
			ncc(){ sudo -u www-data php /var/www/nextcloud/occ "$@"; }

			# Adjusting config file:
			local config_php='/var/www/nextcloud/config/config.php'

			local datadir=$(sed -n '/^[[:blank:]]*SOFTWARE_NEXTCLOUD_DATADIR=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
			[[ $datadir ]] || datadir='/mnt/dietpi_userdata/nextcloud_data'
			G_EXEC mkdir -p "$datadir"
			G_EXEC chown -R www-data:www-data /var/www/nextcloud "$datadir"

			if [[ -d '/mnt/dietpi_userdata/mysql/nextcloud' ]]; then

				G_DIETPI-NOTIFY 2 'Nextcloud database found, will NOT overwrite.'
				if [[ ! -f $config_php ]]; then

					G_WHIP_MSG '[WARNING] Existing Nextcloud database was found, but no related install directory\n
A remaining MariaDB "nextcloud" database from an earlier installed instance was found. But the related install directory "/var/www/nextcloud/config/config.php" does not exist.
Since running a fresh install with an existing database can produce data corruption, if the versions do not exactly match, you either need to remove the database or find and place the related install directory.\n
We cannot predict your aim and do not want to mess or break your data, so please do this manually.\n
To remove the existing database (including e.g. contacts, calendar, file tags etc.):
	# mysqladmin drop nextcloud
Otherwise to copy an existing instance in place:
	# rm -R /var/www/nextcloud
	# mkdir /var/www/nextcloud
	# cp -a /path/to/existing/nextcloud/. /var/www/nextcloud/
The install script will now exit. After applying one of the the above, rerun dietpi-software, e.g.:
	# dietpi-software install 114'
					/boot/dietpi/dietpi-services start
					exit 1

				fi

			elif [[ -f $datadir/dietpi-nextcloud-database-backup.sql ]]; then

				G_DIETPI-NOTIFY 2 'Nextcloud database backup found, starting recovery...'
				local dbuser=$(grep -m1 "^[[:blank:]]*'dbuser'" "$config_php" | mawk -F\' '{print $4}')
				local dbpass=$(grep -m1 "^[[:blank:]]*'dbpassword'" "$config_php" | mawk -F\' '{print $4}')
				/boot/dietpi/func/create_mysql_db nextcloud "$dbuser" "$dbpass"
				mysql nextcloud < "$datadir/dietpi-nextcloud-database-backup.sql"
				# Adjust database data directory entry, in case it changed due to server migration
				local datadir_old=$(grep -m1 "^[[:blank:]]*'datadirectory'" "$config_php" | mawk -F\' '{print $4}')
				G_EXEC mysql -e "update nextcloud.oc_storages set id='local::$datadir/' where id rlike 'local::$datadir_old';"

			elif ! grep -q "'installed' => true," "$config_php" 2>/dev/null; then

				local username=$(sed -n '/^[[:blank:]]*SOFTWARE_OWNCLOUD_NEXTCLOUD_USERNAME=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
				[[ $username ]] || username='admin'

				# For MariaDB, temporary database admin user needs to be created, as 'root' uses unix_socket login, which cannot be accessed by sudo -u www-data.
				# - Create random temporary alphanumeric 30 characters password
				local nc_password=$(tr -dc '[:alnum:]' < /dev/random | head -c30)
				# - Failsafe: Use non-blocking entropy source, if /dev/random fails
				(( ${#nc_password} == 30 )) || nc_password=$(tr -dc '[:alnum:]' < /dev/urandom | head -c30)
				G_EXEC mysql -e "grant all privileges on *.* to tmp_root@localhost identified by '$nc_password' with grant option;"

				G_EXEC_DESC='Nextcloud ncc install'
				# - Replace password strings internally to avoid printing it to console
				G_EXEC_PRE_FUNC(){ acommand[6]="--database-pass=$nc_password" acommand[8]="--admin-pass=$GLOBAL_PW"; }
				# - Checking output for stack trace to handle internal errors that do not lead to php error exit code
				# - Workaround Nextcloud 14.0.3 throwing an error, when data dir path contains a symlink: https://github.com/nextcloud/server/issues/12247
				G_EXEC_POST_FUNC(){

					if (( $exit_code )); then

						grep -q 'Following symlinks is not allowed' "$fp_log" && { cp -a /var/www/nextcloud/core/skeleton/. "$datadir/$username/files/"; exit_code=0; }

					else

						grep -qi 'Stack trace' "$fp_log" && exit_code=255

					fi

				}
				G_EXEC ncc maintenance:install --no-interaction --database='mysql' --database-name='nextcloud' --database-user='tmp_root' --database-pass="${nc_password//?/X}" --admin-user="$username" --admin-pass="${GLOBAL_PW//?/X}" --data-dir="$datadir"
				G_EXEC mysql -e 'drop user tmp_root@localhost;'
				unset -v nc_password

				# Remove obsolete default data dir
				[[ $(readlink -f "$datadir") != $(readlink -f /var/www/nextcloud/data) ]] && G_EXEC rm -R /var/www/nextcloud/data

			fi

			# Enable Nextcloud to use 4-byte database
			G_CONFIG_INJECT "'mysql.utf8mb4'" "'mysql.utf8mb4' => true," "$config_php" "'dbpassword'"

			# Disable trusted_domains.
			grep -q "1 => '*'" "$config_php" || sed -i "/0 => 'localhost'/a     1 => '*'," "$config_php"

			# Set CLI URL to Nextcloud sub directory:
			G_EXEC sed -i "s|'http://localhost'|'http://localhost/nextcloud'|" "$config_php"

			# Set pretty URLs (without /index.php/) on Apache:
			if (( ${aSOFTWARE_INSTALL_STATE[83]} > 0 )); then

				GCI_PRESERVE=1 G_CONFIG_INJECT "'htaccess.RewriteBase'" "'htaccess.RewriteBase' => '/nextcloud'," "$config_php" "'overwrite.cli.url'"
				ncc maintenance:update:htaccess

			fi

			# APCu Memcache
			GCI_PRESERVE=1 G_CONFIG_INJECT "'memcache.local'" "'memcache.local' => '\\\\OC\\\\Memcache\\\\APCu'," "$config_php" "'version'"

			# Redis for transactional file locking:
			G_DIETPI-NOTIFY 2 'Enabling Redis for transactional file locking.' # https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/files_locking_transactional.html
			local redis_conf="/etc/redis/redis.conf"
			# - Enable Redis socket and grant www-data access to it
			GCI_PRESERVE=1 G_CONFIG_INJECT 'unixsocket[[:blank:]]' 'unixsocket /run/redis/redis-server.sock' "$redis_conf"
			G_CONFIG_INJECT 'unixsocketperm[[:blank:]]' 'unixsocketperm 770' "$redis_conf"
			G_EXEC usermod -aG redis www-data
			G_EXEC systemctl restart redis-server
			# - Enable Nextcloud to use Redis socket:
			G_CONFIG_INJECT "'filelocking.enabled'" "'filelocking.enabled' => true," "$config_php" "'memcache.local'"
			local redis_sock=$(grep -m1 '^[[:blank:]]*unixsocket[[:blank:]]' "$redis_conf" | mawk '{print $2}') # Re-estimate in case of existing custom path
			GCI_PRESERVE=1 GCI_NEWLINE=1 G_CONFIG_INJECT "'memcache.locking'" "'memcache.locking' => '\\\\OC\\\\Memcache\\\\Redis',\n'redis' => array ('host' => '$redis_sock', 'port' => 0,)," "$config_php" "'filelocking.enabled'"

			# Tweak Argon2 hashing
			# - Use all available CPU threads
			GCI_PRESERVE=1 G_CONFIG_INJECT "'hashingThreads'" "'hashingThreads' => ${G_HW_CPU_CORES}," "$config_php" "'version'"
			# - ToDo: Configure the other settings after getting some clarification: https://github.com/nextcloud/server/pull/19023#issuecomment-660071524
			#GCI_PRESERVE=1 G_CONFIG_INJECT "'hashingMemoryCost'" "'hashingMemoryCost' => 65536," $config_php "'hashingThreads'"
			#GCI_PRESERVE=1 G_CONFIG_INJECT "'hashingTimeCost'" "'hashingTimeCost' => 4," $config_php "'hashingMemoryCost'"

			# Enable Nextcloud background cron job: https://docs.nextcloud.com/server/17/admin_manual/configuration_server/background_jobs_configuration.html#cron
			crontab -u www-data -l | grep -q '/var/www/nextcloud/cron.php' || { crontab -u www-data -l; echo '*/5 * * * * php /var/www/nextcloud/cron.php'; } | crontab -u www-data -
			ncc background:cron

			# Convert filecache table to bigint, which is not done automatically by Nextcloud since v15
			ncc db:convert-filecache-bigint -n

			# Add missing database columns and indices, which is not done automatically by Nextcloud
			ncc db:add-missing-columns
			ncc db:add-missing-indices
			ncc db:add-missing-primary-keys

			# On <1 GiB devices assure at least 512 MiB swap space are available to stand 512 MiB file uploads + increased PHP cache and session file usage: https://github.com/MichaIng/DietPi/issues/2293
			(( $RAM_PHYS < 924 && $(free -m | mawk '/^Swap:/{print $2;exit}') < 512 )) && /boot/dietpi/func/dietpi-set_swapfile 512
		fi

#### --------------------------- NEXTCLOUD ------------------------------------------- {end}















#### --------------------------- NEXTCLOUD TALK -------------------------------------- {begin}



		if To_Install 168 coturn # Nextcloud Talk
		then
			G_DIETPI-NOTIFY 2 'Installing Coturn TURN server'

			# Install Coturn server only, install Nextcloud Talk app after Nextcloud has been fully configured
			G_AGI coturn
			G_EXEC systemctl stop coturn
			Remove_SysV coturn 1

			# Ask user for server domain and desired TURN server port
			local invalid_text=
			local domain=$(hostname -f)
			while :
			do
				G_WHIP_DEFAULT_ITEM=$domain
				if G_WHIP_INPUTBOX "${invalid_text}Please enter your server's external domain to allow Nextcloud Talk access your TURN server:"
				then
					domain=${G_WHIP_RETURNED_VALUE#http*://}
					break
				else
					invalid_text='[ERROR] This input is required!\n\n'
				fi
			done
			invalid_text=
			local port=3478
			while :
			do
				G_WHIP_DEFAULT_ITEM=$port
				if G_WHIP_INPUTBOX "${invalid_text}Please enter the network port, that should be used for your TURN server:
\nNB: This port (UDP + TCP) needs to be forwarded by your router and/or opened in your firewall settings. Default value is: 3478" && disable_error=1 G_CHECK_VALIDINT "$G_WHIP_RETURNED_VALUE" 0
				then
					port=$G_WHIP_RETURNED_VALUE
					break
				else
					invalid_text='[ERROR] No valid entry found, value needs to be a sequence of integers. Please retry...\n\n'
				fi
			done

			# Adjust Coturn settings
			# - If /etc/turnserver.conf is not present, use default or create empty file
			if [[ ! -f '/etc/turnserver.conf' ]]
			then
				# shellcheck disable=SC2015
				[[ -f '/usr/share/doc/coturn/examples/etc/turnserver.conf.gz' ]] && gzip -cd /usr/share/doc/coturn/examples/etc/turnserver.conf.gz > /etc/turnserver.conf || > /etc/turnserver.conf
			fi
			# https://help.nextcloud.com/t/howto-setup-nextcloud-talk-with-turn-server/30794
			G_CONFIG_INJECT 'listening-port=' "listening-port=$port" /etc/turnserver.conf
			G_CONFIG_INJECT 'fingerprint' 'fingerprint' /etc/turnserver.conf
			G_CONFIG_INJECT 'use-auth-secret' 'use-auth-secret' /etc/turnserver.conf
			G_CONFIG_INJECT 'realm=' "realm=$domain" /etc/turnserver.conf
			GCI_PRESERVE=1 G_CONFIG_INJECT 'total-quota=' 'total-quota=100' /etc/turnserver.conf
			GCI_PRESERVE=1 G_CONFIG_INJECT 'bps-capacity=' 'bps-capacity=0' /etc/turnserver.conf
			G_CONFIG_INJECT 'stale-nonce' 'stale-nonce' /etc/turnserver.conf
			G_EXEC sed -i 's/^[[:blank:]]*allow-loopback-peers/#allow-loopback-peers/' /etc/turnserver.conf
			G_CONFIG_INJECT 'no-multicast-peers' 'no-multicast-peers' /etc/turnserver.conf

			# Install Nextcloud Talk app
			G_EXEC systemctl start mariadb
			G_EXEC systemctl start redis-server
			G_EXEC ncc maintenance:mode --off
			if [[ ! -d '/var/www/nextcloud/apps/spreed' ]]
			then
				# Succeed if app is already installed and on "Cannot declare class" bug: https://github.com/MichaIng/DietPi/issues/3499#issuecomment-622955490
				G_EXEC_POST_FUNC(){ [[ $exit_code != 0 && $(<"$fp_log") =~ (' already installed'$|' Cannot declare class ') ]] && exit_code=0; }
				G_EXEC ncc app:install spreed
			fi
			ncc app:enable spreed

			# Adjust Nextcloud Talk settings to use Coturn
			ncc config:app:set spreed stun_servers --value="[\"$domain:$port\"]"
			# - Generate random secret to secure TURN server access
			local secret=$(openssl rand -hex 32)
			GCI_PASSWORD=1 GCI_PRESERVE=1 G_CONFIG_INJECT 'static-auth-secret=' "static-auth-secret=$secret" /etc/turnserver.conf
			# - Scrape existing secret, in case user manually chose/edited it
			secret=$(sed -n '/^[[:blank:]]*static-auth-secret=/{s/^[^=]*=//p;q}' /etc/turnserver.conf)
			ncc config:app:set spreed turn_servers --value="[{\"server\":\"$domain:$port\",\"secret\":\"$secret\",\"protocols\":\"udp,tcp\"}]" | sed 's/"secret":".*","protocols"/"secret":"<OMITTED>","protocols"/'
			unset -v secret domain port invalid_text
		fi

#### --------------------------- NEXTCLOUD TALK -------------------------------------- {end}












#### --------------------------- FRP -------------------------------------- {begin}

		if To_Install 171 # frp
		then
			case $G_HW_ARCH in
				3) local arch='arm64';;
				10) local arch='amd64';;
				11) local arch='riscv64';;
				*) local arch='arm';;
			esac

			# Download
			local fallback_url="https://github.com/fatedier/frp/releases/download/v0.49.0/frp_0.49.0_linux_$arch.tar.gz"
			Download_Install "$(curl -sSfL 'https://api.github.com/repos/fatedier/frp/releases/latest' | mawk -F\" "/\"browser_download_url\": .*\/frp_[0-9.]*_linux_$arch\.tar\.gz\"/{print \$4}")"

			G_EXEC cd frp_*

			local choice_required=
			while :
			do
				G_WHIP_MENU_ARRAY=(
					'Server' ': Use this machine as a server, with a public IP'
					'Client' ': Use this machine as a client, without a public IP'
					'Both' ': Run the reverse proxy only on this machine'
				)

				G_WHIP_MENU "${choice_required}Please choose how you are going to run frp." && break
				choice_required='[ERROR] A choice is required to finish the frp install.\n\n'
			done
			local mode=$G_WHIP_RETURNED_VALUE

			[[ -d '/etc/frp' ]] || G_EXEC mkdir /etc/frp
			Create_User frp -d /etc/frp

			local token=
			if [[ $mode == 'Server' || $mode == 'Both' ]]
			then
				G_EXEC mv frps /usr/local/bin/frps
				cat << '_EOF_' > /etc/systemd/system/frps.service
[Unit]
Description=frp server (DietPi)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=frp
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.ini
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
_EOF_
				# Pre-create config file to turn on dashboard
				token=$(openssl rand -hex 15)
				[[ -f '/etc/frp/frps.ini' ]] || cat << _EOF_ > /etc/frp/frps.ini
[common]
bind_port = 7000

dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = $GLOBAL_PW

authentication_method = token
token = $token
_EOF_
				G_EXEC chmod 0640 /etc/frp/frps.ini
				G_EXEC chown root:frp /etc/frp/frps.ini
				aENABLE_SERVICES+=('frps')
			fi

			if [[ $mode == 'Client' || $mode == 'Both' ]]
			then
				G_EXEC mv frpc /usr/local/bin/frpc
				cat << '_EOF_' > /etc/systemd/system/frpc.service
[Unit]
Description=frp client (DietPi)
Wants=network-online.target
After=network-online.target frps.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=frp
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.ini
ExecReload=/usr/local/bin/frpc reload -c /etc/frp/frpc.ini
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
_EOF_
				local server_addr=127.0.0.1 server_port=7000
				if [[ $G_WHIP_RETURNED_VALUE == 'Client' ]]
				then
					local invalid_entry=
					while :
					do
						if G_WHIP_INPUTBOX "${invalid_entry}Please enter the IP address of your frp server, including port (default 7000)" && [[ $G_WHIP_RETURNED_VALUE =~ ^[0-9.:]+$ ]]
						then
							server_addr=${G_WHIP_RETURNED_VALUE#*:}
							[[ $G_WHIP_RETURNED_VALUE =~ : ]] && server_port=${G_WHIP_RETURNED_VALUE%:*}
							invalid_entry=
							break
						else
							invalid_entry='[FAILED] Please enter a valid IP address\n\n'
						fi
					done

					while :
					do
						if G_WHIP_INPUTBOX "${invalid_entry}Please enter the authentication token of your frp server" && [[ $G_WHIP_RETURNED_VALUE =~ ^[0-9.]+$ ]]
						then
							token=$G_WHIP_RETURNED_VALUE
							break
						else
							invalid_entry='[FAILED] Please enter a token\n\n'
						fi
					done
				fi

				# Pre-create config file to turn on admin UI
				[[ -f '/etc/frp/frpc.ini' ]] || cat << _EOF_ > /etc/frp/frpc.ini
[common]
server_addr = $server_addr
server_port = $server_port

admin_addr = 0.0.0.0
admin_port = 7400
admin_user = admin
admin_pwd = $GLOBAL_PW

token=$token
_EOF_
				G_EXEC chmod 0660 /etc/frp/frpc.ini
				G_EXEC chown root:frp /etc/frp/frpc.ini
				aENABLE_SERVICES+=('frpc')
			fi

			# Cleanup
			G_EXEC cd "$G_WORKING_DIR"
			G_EXEC rm -R frp_*
		fi


#### --------------------------- FRP -------------------------------------- {end}

























	}

	Uninstall_Software()
	{
		# $1: Service name
		# $2: Remove user named $2 or $1 if $2 == 1 (optional)
		# $3: Remove group named $3 or $1 if $3 == 1 (optional)
		Remove_Service()
		{
			local unmasked disabled
			if [[ -f '/etc/systemd/system/'$1'.service' ]]
			then
				G_EXEC systemctl --no-reload disable --now "$1" && disabled=1
				G_EXEC rm "/etc/systemd/system/$1.service" && unmasked=1

			elif [[ -f '/lib/systemd/system/'$1'.service' ]]
			then
				G_EXEC systemctl --no-reload unmask "$1" && unmasked=1
				G_EXEC systemctl --no-reload disable --now "$1" && disabled=1
			fi
			if [[ -f '/etc/init.d/'$1 ]]
			then
				[[ $unmasked ]] || G_EXEC systemctl --no-reload unmask "$1"
				[[ $disabled ]] || G_EXEC systemctl --no-reload disable "$1"
				[[ $disabled ]] || G_EXEC systemctl stop "$1" # --now does not work with generated wrapper units
				G_EXEC rm "/etc/init.d/$1"
				G_EXEC update-rc.d "$1" remove
			fi
			[[ -d '/etc/systemd/system/'$1'.service.d' ]] && G_EXEC rm -R "/etc/systemd/system/$1.service.d"
			[[ $2 ]] && getent passwd "${2/#1/$1}" > /dev/null && G_EXEC userdel "${2/#1/$1}"
			[[ $3 ]] && getent group "${3/#1/$1}" > /dev/null && G_EXEC groupdel "${3/#1/$1}"
		}

		# $1: Database and username
		Remove_Database()
		{
			systemctl start mariadb || return 1
			mysqladmin -f drop "$1"
			mysql -e "drop user $1@localhost;"
		}

		# NB: "systemctl daemon-reload" is executed at the end of this function
		G_NOTIFY_3_MODE='Step'
		local software_id

		To_Uninstall()
		{
			(( ${aSOFTWARE_INSTALL_STATE[$1]} == -1 )) || return 1
			G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "Uninstalling ${aSOFTWARE_NAME[$1]}: ${aSOFTWARE_DESC[$1]}"
			software_id=$1
		}

	
		if To_Uninstall 168 # Nextcloud Talk + Coturn server
		then
			Remove_Service coturn
			G_AGP coturn
			[[ -f '/etc/turnserver.conf' ]] && G_EXEC rm /etc/turnserver.conf
			systemctl start redis-server
			if systemctl start mariadb
			then
				sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
				sudo -u www-data php /var/www/nextcloud/occ app:disable spreed
			fi
			G_DIETPI-NOTIFY 2 'Disabled Nextcloud Talk app, but you need to remove it manually from Nextcloud web UI, if desired.'
		fi





		if To_Uninstall 114 # Nextcloud
		then
			crontab -u www-data -l | grep -v '/var/www/nextcloud/cron.php' | crontab -u www-data -
			# Disable and remove PHP modules
			command -v phpdismod > /dev/null && G_EXEC phpdismod dietpi-nextcloud
			G_EXEC rm -f /etc/php/*/mods-available/dietpi-nextcloud.ini
			# Disable and remove webserver configs
			command -v a2dissite > /dev/null && a2dissite dietpi-nextcloud
			[[ -f '/etc/apache2/sites-available/dietpi-nextcloud.conf' ]] && G_EXEC rm /etc/apache2/sites-available/dietpi-nextcloud.conf
			[[ -f '/etc/nginx/sites-dietpi/dietpi-nextcloud.conf' ]] && G_EXEC rm /etc/nginx/sites-dietpi/dietpi-nextcloud.conf
			command -v lighty-disable-mod > /dev/null && lighty-disable-mod dietpi-nextcloud
			[[ -f '/etc/lighttpd/conf-available/99-dietpi-nextcloud.conf' ]] && G_EXEC rm /etc/lighttpd/conf-available/99-dietpi-nextcloud.conf
			G_WHIP_MSG "DietPi will perform an automated backup of your Nextcloud database and installation directory, which will be stored inside your Nextcloud data directory.\n\nThe data directory won't be removed. So you can recover your whole Nextcloud instance any time later.\n\nRemove the data directory manually, if you don't need it anymore."
			# Find datadir for backups
			local datadir=$(grep -m1 "^[[:blank:]]*'datadirectory'" /var/www/nextcloud/config/config.php | mawk '{print $3}' | sed "s/[',]//g")
			[[ $datadir ]] || datadir='/mnt/dietpi_userdata/nextcloud_data'
			# Drop MariaDB users and database
			if systemctl start mariadb
			then
				local dbuser=$(grep -m1 "^[[:blank:]]*'dbuser'" /var/www/nextcloud/config/config.php | mawk '{print $3}' | sed 's/,//')
				local dbhost=$(grep -m1 "^[[:blank:]]*'dbhost'" /var/www/nextcloud/config/config.php | mawk '{print $3}' | sed 's/,//')
				mysql -e "drop user $dbuser@$dbhost;"
				mysql -e "drop user $dbuser;" 2> /dev/null
				# Perform database backup if existent, otherwise skip to not overwrite existing one
				[[ -d '/mnt/dietpi_userdata/mysql/nextcloud' ]] && mysqldump nextcloud > "$datadir/dietpi-nextcloud-database-backup.sql"
				mysqladmin drop nextcloud -f
			fi
			if [[ -d '/var/www/nextcloud' ]]
			then
				# Backup Nextcloud installation dir
				G_EXEC cp -a /var/www/nextcloud/. "$datadir/dietpi-nextcloud-installation-backup/"
				# Remove Nextcloud installation dir
				G_EXEC rm -R /var/www/nextcloud
			fi
			# Remove redirect configs
			if grep -q 'nextcloud' /etc/lighttpd/conf-available/99-dietpi-dav_redirect.conf 2> /dev/null
			then
				command -v lighty-disable-mod > /dev/null && lighty-disable-mod dietpi-dav_redirect
				G_EXEC rm /etc/lighttpd/conf-available/99-dietpi-dav_redirect.conf
			fi
			if grep -q 'nextcloud' /etc/apache2/conf-available/dietpi-dav_redirect.conf 2> /dev/null
			then
				command -v a2disconf > /dev/null && a2disconf dietpi-dav_redirect
				G_EXEC rm /etc/apache2/conf-available/dietpi-dav_redirect.conf
			fi
			grep -q 'nextcloud' /etc/nginx/sites-dietpi/dietpi-dav_redirect.conf 2> /dev/null && G_EXEC rm /etc/nginx/sites-dietpi/dietpi-dav_redirect.conf
		fi

	

	Run_Installations()
	{
		G_NOTIFY_3_MODE='Step'
		#------------------------------------------------------------
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Checking for conflicts and missing inputs'

		# Unmark software which requires user input during automated installs
		Unmark_Unattended

		# Unmark conflicting software if not done after interactive software selection already
		(( $CONFLICTS_RESOLVED )) || Unmark_Conflicts

		# Abort install if no selections are left and not first run setup
		if (( $G_DIETPI_INSTALL_STAGE == 2 ))
		then
			local abort=1
			for i in "${!aSOFTWARE_NAME[@]}"
			do
				(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) || continue
				abort=0
				break
			done
			(( $abort )) && { G_DIETPI-NOTIFY 1 'No software installs are done. Aborting...'; exit 1; }
		fi
		#------------------------------------------------------------
		# Disable powersaving on main screen during installation
		command -v setterm > /dev/null && setterm -blank 0 -powersave off 2> /dev/null

		# Mark dependencies for install
		Mark_Dependencies

		# Check network connectivity, DNS resolving and network time sync: https://github.com/MichaIng/DietPi/issues/786
		# - Skip on first run installs where it is done in DietPi-Automation_Pre() already
		(( $G_DIETPI_INSTALL_STAGE == 2 )) || Check_Net_and_Time_sync

		# Pre-create directories which are required for many software installs
		Create_Required_Dirs

		# Read global software password
		Update_Global_Pw

		# Stop all services
		# shellcheck disable=SC2154
		[[ $G_SERVICE_CONTROL == 0 ]] || /boot/dietpi/dietpi-services stop

		# Update package cache: Skip when flag was set by first run setup
		(( $SKIP_APT_UPDATE )) || G_AGUP

		# Install software
		Install_Software

		# Uninstall software, if required by e.g. DietPi choice system
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == -1 )) || continue
			Uninstall_Software
			break
		done

		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Finalising install'

		# Enable installed services
		if [[ ${aENABLE_SERVICES[0]}${aSTART_SERVICES[0]} ]]
		then
			G_DIETPI-NOTIFY 2 'Enabling installed services'
			for i in "${aENABLE_SERVICES[@]}" "${aSTART_SERVICES[@]}"
			do
				G_EXEC_NOHALT=1 G_EXEC systemctl --no-reload enable "$i"
			done
		fi

		# Reload systemd units
		G_EXEC systemctl daemon-reload

		# Unmask systemd-logind if Kodi or Chromium were installed, it's set in dietpi.txt or libpam-systemd was installed
		if [[ $(readlink /etc/systemd/system/systemd-logind.service) == '/dev/null' ]] &&
			{ (( ${aSOFTWARE_INSTALL_STATE[31]} == 1 || ${aSOFTWARE_INSTALL_STATE[113]} == 1 )) || grep -q '^[[:blank:]]*AUTO_UNMASK_LOGIND=1' /boot/dietpi.txt || dpkg-query -s 'libpam-systemd' &> /dev/null; }
		then
			G_DIETPI-NOTIFY 2 'Enabling systemd-logind'
			# dbus is required for systemd-logind to start
			dpkg-query -s dbus &> /dev/null || G_AGI dbus
			G_EXEC systemctl unmask dbus
			G_EXEC systemctl start dbus
			G_EXEC systemctl unmask systemd-logind
			G_EXEC systemctl start systemd-logind
		fi

		# Sync DietPi-RAMlog to disk: https://github.com/MichaIng/DietPi/issues/4884
		systemctl -q is-enabled dietpi-ramlog 2> /dev/null && /boot/dietpi/func/dietpi-ramlog 1

		# Apply GPU Memory Splits
		Install_Apply_GPU_Settings

		# Offer to change DietPi-AutoStart option
		if (( $G_DIETPI_INSTALL_STAGE == 2 )) && ((
			${aSOFTWARE_INSTALL_STATE[23]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[24]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[25]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[26]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[31]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[51]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[108]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[112]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[113]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[119]} == 1 ||
			${aSOFTWARE_INSTALL_STATE[173]} == 1 ))
		then
			G_WHIP_YESNO 'Would you like to configure the DietPi-AutoStart option?
\nThis will allow you to choose which program loads automatically, after the system has booted up, e.g.:
 - Console\n - Desktop\n - Kodi' && /boot/dietpi/dietpi-autostart
		fi

		# Install finished, set all installed software to state 2 (installed)
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && aSOFTWARE_INSTALL_STATE[$i]=2
		done

		# Write to .installed state file
		Write_InstallFileList
	}

	#/////////////////////////////////////////////////////////////////////////////////////
	# First Run / Automation function
	#/////////////////////////////////////////////////////////////////////////////////////
	# Setup steps prior to software installs
	DietPi-Automation_Pre()
	{
		G_NOTIFY_3_MODE='Step'

		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Applying initial first run setup steps'

		# Get settings
		AUTOINSTALL_ENABLED=$(sed -n '/^[[:blank:]]*AUTO_SETUP_AUTOMATED=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		AUTOINSTALL_AUTOSTARTTARGET=$(sed -n '/^[[:blank:]]*AUTO_SETUP_AUTOSTART_TARGET_INDEX=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		local AUTOINSTALL_SSHINDEX=$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		local AUTOINSTALL_FILESERVERINDEX=$(sed -n '/^[[:blank:]]*AUTO_SETUP_FILE_SERVER_INDEX=/{s/^[^=]*=//p;q}' /boot/dietpi.txt) # pre-v7.9
		local AUTOINSTALL_LOGGINGINDEX=$(sed -n '/^[[:blank:]]*AUTO_SETUP_LOGGING_INDEX=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		AUTOINSTALL_CUSTOMSCRIPTURL=$(sed -n '/^[[:blank:]]*AUTO_SETUP_CUSTOM_SCRIPT_EXEC=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		local AUTOINSTALL_TIMESYNCMODE=$(sed -n '/^[[:blank:]]*CONFIG_NTP_MODE=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		local AUTOINSTALL_RESTORE=$(sed -n '/^[[:blank:]]*AUTO_SETUP_BACKUP_RESTORE=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		local AUTOINSTALL_RAMLOG_SIZE=$(sed -n '/^[[:blank:]]*AUTO_SETUP_RAMLOG_MAXSIZE=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		AUTO_SETUP_DHCP_TO_STATIC=$(sed -n '/^[[:blank:]]*AUTO_SETUP_DHCP_TO_STATIC=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)

		# Else set defaults
		[[ $AUTOINSTALL_ENABLED ]] || AUTOINSTALL_ENABLED=0
		[[ $AUTOINSTALL_AUTOSTARTTARGET ]] || AUTOINSTALL_AUTOSTARTTARGET=0
		[[ $AUTOINSTALL_SSHINDEX ]] || AUTOINSTALL_SSHINDEX=-1
		[[ $AUTOINSTALL_FILESERVERINDEX ]] || AUTOINSTALL_FILESERVERINDEX=0 # pre-v7.9
		[[ $AUTOINSTALL_LOGGINGINDEX ]] || AUTOINSTALL_LOGGINGINDEX=-1
		[[ $AUTOINSTALL_CUSTOMSCRIPTURL ]] || AUTOINSTALL_CUSTOMSCRIPTURL=0
		[[ $AUTOINSTALL_TIMESYNCMODE ]] || AUTOINSTALL_TIMESYNCMODE=2
		[[ $AUTOINSTALL_RESTORE ]] || AUTOINSTALL_RESTORE=0
		[[ $AUTOINSTALL_RAMLOG_SIZE ]] || AUTOINSTALL_RAMLOG_SIZE=50
		[[ $AUTO_SETUP_DHCP_TO_STATIC == 1 ]] || AUTO_SETUP_DHCP_TO_STATIC=0

		# Restore DietPi-Backup
		if (( $AUTOINSTALL_RESTORE )); then

			# Reboot only when backup restore succeeded
			restore_succeeded=0

			G_DIETPI-NOTIFY 2 'DietPi-Backup restore selected, scanning and mounting attached drives...'
			i=0
			while read -r line
			do
				# Mount drives to temporary mount points
				mkdir -p "/mnt/dietpi-backup$i" && mount "$line" "/mnt/dietpi-backup$i"
				((i++))

			done < <(lsblk -rnpo NAME,UUID,MOUNTPOINT | mawk '$2 && ! $3 {print $1}')

			G_DIETPI-NOTIFY 2 'Searching all drives for DietPi-Backup instances...'
			mapfile -t alist < <(find /mnt -type f -name '.dietpi-backup_stats')

			# Interactive restore
			if [[ $AUTOINSTALL_RESTORE == 1 ]]; then

				# Do we have any results?
				if [[ ${alist[0]} ]]
				then
					# Create List for Whiptail
					G_WHIP_MENU_ARRAY=()
					for i in "${alist[@]}"
					do
						last_backup_date=$(sed -n '/ompleted/s/^.*: //p' "$i" | tail -1) # Date of last backup for this backup
						backup_directory=${i%/.dietpi-backup_stats} # Backup directory (minus the backup file), that we can use for target backup directory.
						G_WHIP_MENU_ARRAY+=("$backup_directory" ": $last_backup_date")
					done

					export G_DIETPI_SERVICES_DISABLE=1
					G_WHIP_MENU 'Please select a previous backup to restore:' && /boot/dietpi/dietpi-backup -1 "$G_WHIP_RETURNED_VALUE" && restore_succeeded=1
					unset -v G_DIETPI_SERVICES_DISABLE
				else
					G_WHIP_MSG 'No previous backups were found in /mnt/*. Install will continue like normal.'
				fi

			# Non-interactive restore
			elif [[ $AUTOINSTALL_RESTORE == 2 ]]; then

				# Do we have any results?
				if [[ ${alist[0]} ]]
				then
					# Restore first found backup
					export G_DIETPI_SERVICES_DISABLE=1
					/boot/dietpi/dietpi-backup -1 "${alist[0]%/.dietpi-backup_stats}" && restore_succeeded=1
					unset -v G_DIETPI_SERVICES_DISABLE
				else
					G_DIETPI-NOTIFY 1 'DietPi-Backup auto-restore was selected but no backup has been found in /mnt/*. Install will continue like normal.'
				fi

				# Downgrade dietpi.txt option
				G_CONFIG_INJECT 'AUTO_SETUP_BACKUP_RESTORE=' 'AUTO_SETUP_BACKUP_RESTORE=1' /boot/dietpi.txt

			fi

			# Remove mounted drives and mount points
			findmnt /mnt/dietpi-backup[0-9]* > /dev/null && umount /mnt/dietpi-backup[0-9]*
			[[ -d '/mnt/dietpi-backup0' ]] && rmdir /mnt/dietpi-backup[0-9]*

			# Reboot on successful restore
			if (( $restore_succeeded ))
			then
				G_DIETPI-NOTIFY 2 'The system will now reboot into the restored system'
				sync # Failsafe
				G_SLEEP 3
				reboot
			fi

		fi

		# Check network connectivity, DNS resolving and network time sync: https://github.com/MichaIng/DietPi/issues/786
		Check_Net_and_Time_sync

		# Full package upgrade on first run installs: https://github.com/MichaIng/DietPi/issues/3098
		if [[ ! -f '/boot/dietpi/.skip_distro_upgrade' ]]
		then
			G_AGUP
			# Do not repeat APT update in Run_Installations()
			SKIP_APT_UPDATE=1
			G_AGDUG
			# Create a persistent flag to not repeat G_AGDUG and rule out a reboot loop when kernel modules remain missing
			G_EXEC eval '> /boot/dietpi/.skip_distro_upgrade'
			# Perform a reboot if required as of missing kernel modules
			G_CHECK_KERNEL || { G_DIETPI-NOTIFY 2 'A reboot is done to finalise the kernel upgrade'; reboot; }
		fi

		# Global PW
		# - Automation: Apply from dietpi.txt
		if (( $AUTOINSTALL_ENABLED ))
		then
			Update_Global_Pw
			# Set again to apply for UNIX users as well
			/boot/dietpi/func/dietpi-set_software passwords "$GLOBAL_PW"

		# - Prompt to change global software password and login passwords for root and dietpi users
		else
			# Local console: Prompt to select keyboard layout first if default is still set: https://github.com/MichaIng/DietPi/issues/5925
			[[ $(tty) == '/dev/tty1' ]] && grep -q 'XKBLAYOUT="gb"' /etc/default/keyboard && dpkg-reconfigure keyboard-configuration && setupcon --save # https://bugs.debian.org/818065
			/boot/dietpi/func/dietpi-set_software passwords
		fi

		# Disable serial console?
		if (( $G_HW_MODEL != 75 )) && ! grep -q '^[[:blank:]]*CONFIG_SERIAL_CONSOLE_ENABLE=0' /boot/dietpi.txt &&
			[[ ! $(tty) =~ ^/dev/(tty(S|AMA|SAC|AML|SC|GS|FIQ|MV)|hvc)[0-9]$ ]] &&
			G_WHIP_BUTTON_OK_TEXT='Yes' G_WHIP_BUTTON_CANCEL_TEXT='No' G_WHIP_YESNO 'A serial/UART console is currently enabled, would you like to disable it?
\nTL;DR: If you do not know what a UART device or a serial console is, it is safe to select "Yes", which frees some MiB memory by stopping the related process(es).
\nA serial console is a way to interact with a system without any screen or network (SSH) required, but from another system physically connected. It is accessed with a UART adapter cable (often UART-to-USB), connected to a special UART port or GPIO pins. It can then be accessed via COM port from the attached system with a serial console client, e.g. PuTTY (which supports both, SSH and serial console access).
\nAnother benefit is that you can view early boot logs, before network or even screen output is up, which makes it a great way to debug issues with the bootloader or kernel. However, to allow as well common user logins via serial console, at least one additional login prompt process is running, which you may want to avoid when not using this feature at all.
\nSerial consoles can re-enabled at any time via dietpi-config > Advanced Options > Serial/UART'
		then
			/boot/dietpi/func/dietpi-set_hardware serialconsole disable
		fi

		# RPi: Convert "serial0" to its actual symlink target without breaking the possibly currently used serial connection or starting a doubled console on the same serial device.
		if (( $G_HW_MODEL < 10 ))
		then
			if [[ -e '/dev/serial0' ]] && ! grep -q '^[[:blank:]]*CONFIG_SERIAL_CONSOLE_ENABLE=0' /boot/dietpi.txt
			then
				local tty=$(readlink -f /dev/serial0); tty=${tty#/dev/}
				if [[ $(</boot/cmdline.txt) == *'console=serial0'* ]]
				then
					if [[ $(</boot/cmdline.txt) == *"console=$tty"* ]]
					then
						G_EXEC sed -Ei 's/[[:blank:]]*console=serial0[^[:blank:]]*([[:blank:]]*$)?//' /boot/cmdline.txt
					else
						G_EXEC sed -i "s/console=serial0/console=$tty/" /boot/cmdline.txt
					fi
				fi
				if systemctl -q is-enabled serial-getty@serial0
				then
					G_EXEC systemctl --no-reload disable serial-getty@serial0
					G_EXEC systemctl --no-reload unmask "serial-getty@$tty"
					G_EXEC systemctl --no-reload enable "serial-getty@$tty"
				fi
				unset -v tty
			else
				/boot/dietpi/func/dietpi-set_hardware serialconsole disable serial0
			fi
		fi

		# Apply RAMlog size
		sed -i "\|[[:blank:]]/var/log[[:blank:]]|c\tmpfs /var/log tmpfs size=${AUTOINSTALL_RAMLOG_SIZE}M,noatime,lazytime,nodev,nosuid" /etc/fstab
		findmnt /var/log > /dev/null && G_EXEC mount -o remount /var/log

		# Set time sync mode if no container system
		(( $G_HW_MODEL == 75 )) || /boot/dietpi/func/dietpi-set_software ntpd-mode "$AUTOINSTALL_TIMESYNCMODE"

		# Apply choice and preference system settings
		Apply_SSHServer_Choices "$AUTOINSTALL_SSHINDEX"
		Apply_Logging_Choices "$AUTOINSTALL_LOGGINGINDEX"
		# - Pre-v7.9
		case "$AUTOINSTALL_FILESERVERINDEX" in

			'-1') (( ${aSOFTWARE_INSTALL_STATE[94]} == 2 )) || aSOFTWARE_INSTALL_STATE[94]=1;;
			'-2') (( ${aSOFTWARE_INSTALL_STATE[96]} == 2 )) || aSOFTWARE_INSTALL_STATE[96]=1;;
			*) :;;

		esac

		G_DIETPI-NOTIFY 0 'Applied initial first run setup steps'

		# Automated installs
		(( $AUTOINSTALL_ENABLED > 0 )) || return 0

		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Running automated install'

		TARGETMENUID=-1 # Skip menu loop
		GOSTARTINSTALL=1 # Set install start flag

		# Find all software entries of AUTO_SETUP_INSTALL_SOFTWARE_ID= in dietpi.txt. Then set to state 1 for installation.
		G_DIETPI-NOTIFY 2 'Checking AUTO_SETUP_INSTALL_SOFTWARE_ID entries'
		while read -r software_id
		do
			# Skip if software does not exist, is not supported on architecture, hardware model or Debian version
			if [[ ! ${aSOFTWARE_NAME[$software_id]} ]]
			then
				G_DIETPI-NOTIFY 1 "Software title with ID $software_id does not exist. Skipping it."

			elif (( ! ${aSOFTWARE_AVAIL_G_HW_ARCH[$software_id,$G_HW_ARCH]:=1} ))
			then
				G_DIETPI-NOTIFY 1 "Software title ${aSOFTWARE_NAME[$software_id]} is not supported on $G_HW_ARCH_NAME systems. Skipping it."

			elif (( ! ${aSOFTWARE_AVAIL_G_HW_MODEL[$software_id,$G_HW_MODEL]:=1} ))
			then
				G_DIETPI-NOTIFY 1 "Software title ${aSOFTWARE_NAME[$software_id]} is not supported on $G_HW_MODEL_NAME. Skipping it."

			elif (( ! ${aSOFTWARE_AVAIL_G_DISTRO[$software_id,$G_DISTRO]:=1} )); then

				G_DIETPI-NOTIFY 1 "Software title ${aSOFTWARE_NAME[$software_id]} is not supported on Debian ${G_DISTRO_NAME^}. Skipping it."
			else
				aSOFTWARE_INSTALL_STATE[$software_id]=1
				G_DIETPI-NOTIFY 0 "Software title ${aSOFTWARE_NAME[$software_id]} flagged for installation."
			fi

		done < <(grep '^[[:blank:]]*AUTO_SETUP_INSTALL_SOFTWARE_ID=' /boot/dietpi.txt | mawk '{print $1}' | sed 's/[^0-9]*//g')
	}

	# Setup steps after software installs
	DietPi-Automation_Post()
	{
		G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Applying final first run setup steps'

		# Remove fake-hwclock, if real hwclock is available
		# REMOVED: "hwclock" succeeds if an RTC connector is available but no battery attached (or empty), hence we cannot guarantee correct RTC time on boot by only testing "hwclock".
		#hwclock &> /dev/null && G_AGP fake-hwclock

		# x86_64 PC: Install microcode updates
		if (( $G_HW_MODEL == 21 ))
		then
			grep -qi 'vendor_id.*intel' /proc/cpuinfo && G_AGI intel-microcode
			grep -qi 'vendor_id.*amd' /proc/cpuinfo && G_AGI amd64-microcode

		# VM: Enable QEMU guest agent if detected
		elif (( $G_HW_MODEL == 20 )) && grep -q 'org.qemu.guest_agent.0' /sys/class/virtio-ports/*/name 2> /dev/null
		then
			G_DIETPI-NOTIFY 2 'QEMU VM detected, installing guest agent ...'
			G_AGI dbus
			G_EXEC systemctl unmask systemd-logind
			G_EXEC systemctl start systemd-logind
			G_AGI qemu-guest-agent

		# RPi4 EEPROM update: https://github.com/MichaIng/DietPi/issues/3217
		elif (( $G_HW_MODEL == 4 ))
		then
			/boot/dietpi/func/dietpi-set_hardware rpi-eeprom
		fi

		# Apply DHCP leased network settings as static network settings, if requested
		if (( $AUTO_SETUP_DHCP_TO_STATIC ))
		then
			G_DIETPI-NOTIFY 2 'Applying DHCP leased network settings as static network settings'

			# Function to convert CIDR notation into dot-decimal notation
			cidr2mask()
			{
				local i mask full_octets=$(( $1 / 8 )) partial_octet=$(( $1%8 ))
				for i in {0..3}
				do
					if (( $i < $full_octets ))
					then
						mask+=255

					elif (( $i == $full_octets ))
					then
						mask+=$(( 256 - 2 ** ( 8 - $partial_octet ) ))
					else
						mask+=0
					fi
					(( $i < 3 )) && mask+=.
				done
				echo "$mask"
			}

			# Get Ethernet index
			local nameservers eth_index=$(sed -En '/^[[:blank:]]*(allow-hotplug|auto)[[:blank:]]+eth[0-9]+$/{s/^.*eth//p;q}' /etc/network/interfaces)
			# - Is enabled and uses DHCP
			if [[ $eth_index ]] && grep -Eq "^[[:blank:]]*iface[[:blank:]]+eth${eth_index}[[:blank:]]+inet[[:blank:]]+dhcp$" /etc/network/interfaces
			then
				G_DIETPI-NOTIFY 2 'Applying DHCP leased Ethernet settings as static Ethernet settings'

				# Get current network info
				local eth_ip=$(ip -br -f inet a s "eth$eth_index" | mawk '{print $3}' | sed 's|/.*$||')
				local eth_mask=$(cidr2mask "$(ip -br -f inet a s "eth$eth_index" | mawk '{print $3}' | sed 's|^.*/||')")
				local eth_gateway=$(ip r l dev "eth$eth_index" 0/0 | mawk '{print $3;exit}')
				nameservers=$(mawk '/^[[:blank:]]*nameserver[[:blank:]]/{print $2}' ORS=' ' /etc/resolv.conf)

				# Apply current network settings statically
				G_CONFIG_INJECT "iface[[:blank:]]+eth$eth_index" "iface eth$eth_index inet static" /etc/network/interfaces
				sed -i "0,\|^.*address[[:blank:]].*\$|s||address $eth_ip|" /etc/network/interfaces
				sed -i "0,\|^.*netmask[[:blank:]].*\$|s||netmask $eth_mask|" /etc/network/interfaces
				sed -i "0,\|^.*gateway[[:blank:]].*\$|s||gateway $eth_gateway|" /etc/network/interfaces
			fi

			# Get WiFi index
			local wlan_index=$(sed -En '/^[[:blank:]]*(allow-hotplug|auto)[[:blank:]]+wlan[0-9]+$/{s/^.*wlan//p;q}' /etc/network/interfaces)
			# - Is enabled and uses DHCP
			if [[ $wlan_index ]] && grep -Eq "^[[:blank:]]*iface[[:blank:]]+wlan${wlan_index}[[:blank:]]+inet[[:blank:]]+dhcp$" /etc/network/interfaces
			then
				G_DIETPI-NOTIFY 2 'Applying DHCP leased WiFi settings as static WiFi settings'

				# Get current network info
				local wlan_ip=$(ip -br -f inet a s "wlan$wlan_index" | mawk '{print $3}' | sed 's|/.*$||')
				local wlan_mask=$(cidr2mask "$(ip -br -f inet a s "wlan$wlan_index" | mawk '{print $3}' | sed 's|^.*/||')")
				local wlan_gateway=$(ip r l dev "wlan$wlan_index" 0/0 | mawk '{print $3;exit}')
				[[ $nameservers ]] || nameservers=$(mawk '/^[[:blank:]]*nameserver[[:blank:]]/{print $2}' ORS=' ' /etc/resolv.conf)

				# Apply current network settings statically
				G_CONFIG_INJECT "iface[[:blank:]]+wlan$wlan_index" "iface wlan$wlan_index inet static" /etc/network/interfaces
				sed -i "\|^iface wlan|,\$s|^.*address[[:blank:]].*\$|address $wlan_ip|" /etc/network/interfaces
				sed -i "\|^iface wlan|,\$s|^.*netmask[[:blank:]].*\$|netmask $wlan_mask|" /etc/network/interfaces
				sed -i "\|^iface wlan|,\$s|^.*gateway[[:blank:]].*\$|gateway $wlan_gateway|" /etc/network/interfaces
			fi
			unset -f cidr2mask

			# Apply DNS nameservers
			if [[ $nameservers ]]
			then
				G_DIETPI-NOTIFY 2 'Applying DHCP leased DNS nameservers as static nameservers'

				if command -v resolvconf > /dev/null
				then
					sed -i "/dns-nameservers[[:blank:]]/c\dns-nameservers ${nameservers% }" /etc/network/interfaces
				else
					sed -i "/dns-nameservers[[:blank:]]/c\#dns-nameservers ${nameservers% }" /etc/network/interfaces
					> /etc/resolv.conf
					for i in $nameservers; do echo "nameserver $i" >> /etc/resolv.conf; done
				fi
			fi

			G_DIETPI-NOTIFY 0 'Network changes will become effective with next reboot'
		fi

		# RPi: Disable onboard WiFi if WiFi modules didn't get enabled until now: https://github.com/MichaIng/DietPi/issues/5391
		[[ $G_HW_MODEL -gt 9 || ! -f '/etc/modprobe.d/dietpi-disable_wifi.conf' ]] || /boot/dietpi/func/dietpi-set_hardware wifimodules onboard_disable

		# Apply AutoStart choice
		/boot/dietpi/dietpi-autostart "$AUTOINSTALL_AUTOSTARTTARGET"

		# Disable console on TTY1 for purely headless SBCs, enabled for automated first run setup
		[[ $G_HW_MODEL =~ ^(47|48|55|56|57|59|60|64|65|73)$ ]] && G_EXEC systemctl --no-reload disable getty@tty1

		# Install user set GPU driver from dietpi.txt if set.
		local gpu_current=$(sed -n '/^[[:blank:]]*CONFIG_GPU_DRIVER=/{s/^[^=]*=//p;q}' /boot/dietpi.txt)
		if [[ ${gpu_current,,} != 'none' ]]
		then
			/boot/dietpi/func/dietpi-set_hardware gpudriver "$gpu_current"
		fi

		# Set install stage to finished
		G_DIETPI_INSTALL_STAGE=2
		G_EXEC eval 'echo 2 > /boot/dietpi/.install_stage'

		# Remove now obsolete flag
		[[ -f '/boot/dietpi/.skip_distro_upgrade' ]] && G_EXEC rm /boot/dietpi/.skip_distro_upgrade

		G_DIETPI-NOTIFY 0 'Applied final first run setup steps'

		# Custom 1st run script
		[[ $AUTOINSTALL_CUSTOMSCRIPTURL != '0' || -f '/boot/Automation_Custom_Script.sh' ]] || return 0

		# Download online script
		[[ -f '/boot/Automation_Custom_Script.sh' ]] || G_EXEC_NOEXIT=1 G_EXEC curl -sSfL "$AUTOINSTALL_CUSTOMSCRIPTURL" -o /boot/Automation_Custom_Script.sh || return $?

		G_DIETPI-NOTIFY 2 'Running custom script, please wait...'

		[[ -x '/boot/Automation_Custom_Script.sh' ]] || G_EXEC_NOEXIT=1 G_EXEC chmod +x /boot/Automation_Custom_Script.sh
		/boot/Automation_Custom_Script.sh 2>&1 | tee /var/tmp/dietpi/logs/dietpi-automation_custom_script.log
		G_DIETPI-NOTIFY $(( ! ! ${PIPESTATUS[0]} )) 'Custom script: /var/tmp/dietpi/logs/dietpi-automation_custom_script.log'
	}

	#/////////////////////////////////////////////////////////////////////////////////////
	# Globals
	#/////////////////////////////////////////////////////////////////////////////////////
	Input_Modes()
	{
		# Process software and exit
		if [[ $1 == 'install' || $1 == 'reinstall' || $1 == 'uninstall' ]]; then

			G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" "Automated $1"

			# Make sure we have at least one entry
			[[ $2 ]] || { G_DIETPI-NOTIFY 1 'Please enter at least one software ID to process'; return 1; }

			# Process software IDs
			local command=$1
			shift
			for i in "$@"
			do
				# Check if input software ID exists, install state was defined
				if disable_error=1 G_CHECK_VALIDINT "$i" 0 && disable_error=1 G_CHECK_VALIDINT "${aSOFTWARE_INSTALL_STATE[$i]}"; then

					if [[ $command == 'uninstall' ]]; then

						if (( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 )); then

							aSOFTWARE_INSTALL_STATE[$i]=-1
							G_DIETPI-NOTIFY 0 "Uninstalling ${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}"

						elif (( ${aSOFTWARE_INSTALL_STATE[$i]} != -1 )); then

							G_DIETPI-NOTIFY 2 "$i: ${aSOFTWARE_NAME[$i]} is not currently installed"
							G_DIETPI-NOTIFY 0 "No changes applied for: ${aSOFTWARE_NAME[$i]}"

						fi

					elif [[ $command == 'reinstall' ]]; then

						(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && continue

						if (( ${aSOFTWARE_INSTALL_STATE[$i]} != 2 )); then

							G_DIETPI-NOTIFY 2 "$i: ${aSOFTWARE_NAME[$i]} is not currently installed"
							G_DIETPI-NOTIFY 2 "Use \"dietpi-software install $i\" to install ${aSOFTWARE_NAME[$i]}."
							G_DIETPI-NOTIFY 0 "No changes applied for: ${aSOFTWARE_NAME[$i]}"

						elif (( ! ${aSOFTWARE_AVAIL_G_HW_ARCH[$i,$G_HW_ARCH]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported on $G_HW_ARCH_NAME systems."

						elif (( ! ${aSOFTWARE_AVAIL_G_HW_MODEL[$i,$G_HW_MODEL]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported for $G_HW_MODEL_NAME."

						elif (( ! ${aSOFTWARE_AVAIL_G_DISTRO[$i,$G_DISTRO]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported on Debian ${G_DISTRO_NAME^}."

						else

							aSOFTWARE_INSTALL_STATE[$i]=1
							GOSTARTINSTALL=1 # Set install start flag
							G_DIETPI-NOTIFY 0 "Reinstalling ${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}"

						fi

					elif [[ $command == 'install' ]]; then

						(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && continue

						if (( ! ${aSOFTWARE_AVAIL_G_HW_ARCH[$i,$G_HW_ARCH]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported on $G_HW_ARCH_NAME systems."

						elif (( ! ${aSOFTWARE_AVAIL_G_HW_MODEL[$i,$G_HW_MODEL]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported for $G_HW_MODEL_NAME."

						elif (( ! ${aSOFTWARE_AVAIL_G_DISTRO[$i,$G_DISTRO]:=1} )); then

							G_DIETPI-NOTIFY 1 "Software title (${aSOFTWARE_NAME[$i]}) is not supported on Debian ${G_DISTRO_NAME^}."

						elif (( ${aSOFTWARE_INSTALL_STATE[$i]} != 2 )); then

							aSOFTWARE_INSTALL_STATE[$i]=1
							GOSTARTINSTALL=1 # Set install start flag
							G_DIETPI-NOTIFY 0 "Installing ${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}"

						else

							G_DIETPI-NOTIFY 2 "$i: ${aSOFTWARE_NAME[$i]} is already installed"
							G_DIETPI-NOTIFY 2 "Use \"dietpi-software reinstall $i\" to force rerun of installation and configuration steps for ${aSOFTWARE_NAME[$i]}."
							G_DIETPI-NOTIFY 0 "No changes applied for: ${aSOFTWARE_NAME[$i]}"

						fi

					fi

				fi

			done

			# Reinstall, prompt for backup
			if [[ $command == 'reinstall' && $GOSTARTINSTALL == 1 ]]; then

				G_PROMPT_BACKUP
				CONFLICTS_RESOLVED=1

			# Uninstall | Finish up and clear non-required packages
			elif [[ $command == 'uninstall' ]]; then

				for i in "${!aSOFTWARE_NAME[@]}"
				do
					(( ${aSOFTWARE_INSTALL_STATE[$i]} == -1 )) || continue
					Uninstall_Software
					Write_InstallFileList
					break
				done

			fi

		# List software IDs, names and additional info
		elif [[ $1 == 'list' ]]; then

			if [[ $MACHINE_READABLE ]]
			then
				for i in "${!aSOFTWARE_NAME[@]}"
				do
					# ID
					local string=$i

					# Show if disabled
					(( ${aSOFTWARE_AVAIL_G_HW_ARCH[$i,$G_HW_ARCH]:=1} && ${aSOFTWARE_AVAIL_G_HW_MODEL[$i,$G_HW_MODEL]:=1} && ${aSOFTWARE_AVAIL_G_DISTRO[$i,$G_DISTRO]:=1} )) || string+=' DISABLED'

					# Install state, software name, and description
					string+="|${aSOFTWARE_INSTALL_STATE[$i]}|${aSOFTWARE_NAME[$i]}|${aSOFTWARE_DESC[$i]}|"

					# Append dependencies
					for j in ${aSOFTWARE_DEPS[$i]}
					do
						# Add software name or raw meta dependencies to string
						[[ $j == *[^0-9]* ]] && string+="$j," || string+="${aSOFTWARE_NAME[$j]},"
					done

					echo "${string%,}|${aSOFTWARE_DOCS[$i]}"
				done
			else
				for i in "${!aSOFTWARE_NAME[@]}"
				do
					# ID, install state, software name and description
					local string="ID $i | =${aSOFTWARE_INSTALL_STATE[$i]} | ${aSOFTWARE_NAME[$i]}:\e[0m \e[90m${aSOFTWARE_DESC[$i]}\e[0m |"

					# Paint green if installed
					(( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 )) && string="\e[32m$string"

					# Append dependencies
					for j in ${aSOFTWARE_DEPS[$i]}
					do
						# Add software name or raw meta dependencies to string
						[[ $j == *[^0-9]* ]] && string+=" +$j" || string+=" +${aSOFTWARE_NAME[$j]}"
					done

					# Available for G_HW_ARCH?
					if (( ! ${aSOFTWARE_AVAIL_G_HW_ARCH[$i,$G_HW_ARCH]:=1} )); then

						string+=" \e[31mDISABLED for ${RPI_64KERNEL_32OS:-$G_HW_ARCH_NAME}\e[0m"

					# Available for G_HW_MODEL?
					elif (( ! ${aSOFTWARE_AVAIL_G_HW_MODEL[$i,$G_HW_MODEL]:=1} )); then

						string+=" \e[31mDISABLED for $G_HW_MODEL_NAME\e[0m"

					# Available for G_DISTRO?
					elif (( ! ${aSOFTWARE_AVAIL_G_DISTRO[$i,$G_DISTRO]:=1} )); then

						string+=" \e[31mDISABLED for Debian $G_DISTRO_NAME\e[0m"

					fi

					# Append online docs if available
					[[ ${aSOFTWARE_DOCS[$i]} ]] && string+=" | \e[90m${aSOFTWARE_DOCS[$i]}\e[0m"

					echo -e "$string"
				done
			fi

		elif [[ $1 == 'free' ]]; then

			# Get highest software array index
			local max=0
			for max in "${!aSOFTWARE_NAME[@]}"; do :; done

			# Check for unused indices
			local free=
			for (( i=0; i<=$max; i++ )); do	[[ ${aSOFTWARE_NAME[$i]} ]] || free+=" $i"; done

			echo "Free software ID(s):${free:- None, so use $(($max+1))!}"

		else

			G_DIETPI-NOTIFY 1 "Invalid input command ($1). Aborting...\n$USAGE"
			exit 1

		fi
	}

	#/////////////////////////////////////////////////////////////////////////////////////
	# Whip menus
	#/////////////////////////////////////////////////////////////////////////////////////
	MENU_MAIN_LASTITEM='Help!'
	TARGETMENUID=0

	# $1=search: Show search box and show only matches in menu
	Menu_CreateSoftwareList()
	{
		local i j selected reset=()

		# Search mode
		if [[ $1 == 'search' ]]
		then
			G_WHIP_INPUTBOX 'Please enter a software title, ID or keyword to search, e.g.: desktop/cloud/media/torrent' || return 0

			G_WHIP_CHECKLIST_ARRAY=()

			# Loop through all software titles
			for i in "${!aSOFTWARE_NAME[@]}"
			do
				# Check if this software is available for hardware, arch and distro
				(( ${aSOFTWARE_AVAIL_G_HW_MODEL[$i,$G_HW_MODEL]:=1} && ${aSOFTWARE_AVAIL_G_HW_ARCH[$i,$G_HW_ARCH]:=1} && ${aSOFTWARE_AVAIL_G_DISTRO[$i,$G_DISTRO]:=1} )) || continue

				# Check if input matches software ID, name or description
				[[ $G_WHIP_RETURNED_VALUE == "$i" || ${aSOFTWARE_NAME[$i],,} == *"${G_WHIP_RETURNED_VALUE,,}"* || ${aSOFTWARE_DESC[$i],,} == *"${G_WHIP_RETURNED_VALUE,,}"* ]] || continue

				# Set checkbox based on install state, including previous selection
				(( ${aSOFTWARE_INSTALL_STATE[$i]} > 0 )) && selected='on' || selected='off'

				# Add this software title to whiptail menu
				G_WHIP_CHECKLIST_ARRAY+=("$i" "${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}" "$selected")

				# Add previously selected items to array to be unmarked if deselected when selection is confirmed.
				(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && reset+=("$i")
			done

			(( ${#G_WHIP_CHECKLIST_ARRAY[@]} )) || { G_WHIP_MSG "We couldn't find any available software title for the search term: \"$G_WHIP_RETURNED_VALUE\""; return 0; }

		# Generate whiptail menu list of all software titles, sorted by category
		else
			G_WHIP_CHECKLIST_ARRAY=()

			# Loop through software category IDs
			for i in "${!aSOFTWARE_CATEGORIES[@]}"
			do
				# Add category to whiptail menu
				G_WHIP_CHECKLIST_ARRAY+=('' "${aSOFTWARE_CATEGORIES[$i]}" 'off')

				# Loop through software title IDs
				for j in "${!aSOFTWARE_CATX[@]}"
				do
					# Check if this software's category matches the current category
					(( ${aSOFTWARE_CATX[$j]} == $i )) || continue

					# Check if this software is available for hardware, arch and distro
					(( ${aSOFTWARE_AVAIL_G_HW_MODEL[$j,$G_HW_MODEL]:=1} && ${aSOFTWARE_AVAIL_G_HW_ARCH[$j,$G_HW_ARCH]:=1} && ${aSOFTWARE_AVAIL_G_DISTRO[$j,$G_DISTRO]:=1} )) || continue

					# Set checkbox based on install state, including previous selection
					(( ${aSOFTWARE_INSTALL_STATE[$j]} > 0 )) && selected='on' || selected='off'

					# Add this software title to whiptail menu
					G_WHIP_CHECKLIST_ARRAY+=("$j" "${aSOFTWARE_NAME[$j]}: ${aSOFTWARE_DESC[$j]}" "$selected")

					# Add previously selected items to array to be unmarked if deselected when selection is confirmed.
					(( ${aSOFTWARE_INSTALL_STATE[$j]} == 1 )) && reset+=("$i")
				done
			done
		fi

		G_WHIP_SIZE_X_MAX=93 # Assure this is enough to show full software descriptions + scroll bar
		G_WHIP_BUTTON_OK_TEXT='Confirm'
		G_WHIP_CHECKLIST 'Please use the spacebar to select the software you wish to install. Then press ENTER/RETURN or select <Confirm> to confirm.
 - Press ESC or select <Cancel> to discard changes made.
 - Software and usage details: https://dietpi.com/docs/software/' || return 0

		# Unmark all listed pending state items, so deselected items are not installed.
		for i in "${!reset[@]}"
		do
			aSOFTWARE_INSTALL_STATE[$i]=0
		done

		# Mark selected items for install
		for i in $G_WHIP_RETURNED_VALUE
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 )) || aSOFTWARE_INSTALL_STATE[$i]=1
		done

		# Unmark conflicting software
		Unmark_Conflicts

		#-----------------------------------------------------------------------------
		# Install info/warnings/inputs

		# DietPi-Drive_Manager can be used to setup Samba/NFS shares with ease!
		(( ${aSOFTWARE_INSTALL_STATE[1]} == 1 || ${aSOFTWARE_INSTALL_STATE[110]} == 1 )) && G_WHIP_MSG "[ INFO ] Mount NFS/Samba shares via DietPi-Drive_Manager
\nDietPi-Drive_Manager is a powerful tool which vastly simplifies the mounting of NFS and Samba shares.
\nOnce $G_PROGRAM_NAME has finished installation, simply run 'dietpi-drive_manager' to setup required network mounts."

		# PaperMC: Inform user about long install/startup time and possible swap file usage
		if (( ${aSOFTWARE_INSTALL_STATE[181]} == 1 ))
		then
			local swap_info=
			(( $RAM_PHYS < 924 )) && swap_info='\n\nThe server will be started with with minimal required memory usage, but a swap file will be created to assure that no out-of-memory crash can happen.
On servers with less than 1 GiB physical memory, we strongly recommend to move the swap file to an external drive, if your system runs on an SD card, since during normal PaperMC operation this swap space will be heavily used.'
			G_WHIP_MSG "PaperMC will be started during install to allow pre-configuring it's default configuration files. Especially on smaller SBCs, like Raspberry Pi Zero, this can take a long time.
We allow it to take up to 30 minutes, it's process can be followed, please be patient.$swap_info"
		fi

		# mjpg-streamer: Warn about unprotected stream and inform about additional plugins
		(( ${aSOFTWARE_INSTALL_STATE[137]} == 1 )) && G_WHIP_MSG '[ WARN ] The mjpg-streamer camera stream will be accessible unprotected at port 8082 by default.
\nYou can configure a password protection, but this will break embedding the stream into other web interfaces, like OctoPrint.
\nWe hence recommend to not forward port 8082 through your NAT and/or block public access via firewall.
\nIf you require access from outside your local network to a web interface that embeds the camera stream, we recommend to setup a VPN connection for this.
\nRead more about this matter and how to configure mjpg-streamer at our online documentation: https://dietpi.com/docs/software/camera/#mjpg-streamer
\n[ INFO ] mjpg-streamer will not be compiled with all available plugins by default.
\nIf you require other input or output plugins, simply install the required dependencies. Plugins will be compiled automatically if dependencies are met.
\nFor available plugins and their dependencies, watch the info printed during the build and check out the official GitHub repository: https://github.com/jacksonliam/mjpg-streamer'

		# RPi Cam Web Interface: Warn user of locking out camera: https://github.com/MichaIng/DietPi/issues/249
		(( ${aSOFTWARE_INSTALL_STATE[59]} == 1 )) && G_WHIP_MSG 'RPi Cam Web Interface will automatically start and activate the camera during boot. This will prevent other programs (like raspistill) from using the camera.
\nYou can free up the camera by selecting "Stop Camera" from the web interface:\n - http://myip/rpicam'

		# Offer to install Unbound along with AdGuard Home and Pi-hole
		if (( ${aSOFTWARE_INSTALL_STATE[93]} == 1 || ${aSOFTWARE_INSTALL_STATE[126]} == 1 ))
		then
			# Add option to use Unbound as upstream DNS server
			if (( ${aSOFTWARE_INSTALL_STATE[182]} == 0 ))
			then
				G_WHIP_YESNO 'Would you like to use Unbound, a tiny recursive DNS server hosted on your device, as your upstream DNS server?
\nThis will increase privacy, because you will not be sending data to Google etc.
\nHowever, the downside is that some websites may load slower the first time you visit them.' && aSOFTWARE_INSTALL_STATE[182]=1
			fi

			# Prompt for static IP
			if G_WHIP_YESNO 'A static IP address is essential for a DNS server installations. DietPi-Config can be used to quickly setup your static IP address.
\nIf you have already setup your static IP, please ignore this message.\n\nWould you like to setup your static IP address now?'
			then
				G_WHIP_MSG 'DietPi-Config will now be launched. Simply select your Ethernet or Wifi connection from the menu to access the IP address settings.
\nThe "copy current address to STATIC" menu option can be used to quickly setup your static IP. Please ensure you change the mode "DHCP" to "STATIC".
\nOnce completed, select "Apply Save Changes", then exit DietPi-Config to resume setup.'
				/boot/dietpi/dietpi-config 8
			fi
		fi

		# WiFi Hotspot Criteria
		if (( ${aSOFTWARE_INSTALL_STATE[60]} == 1 || ${aSOFTWARE_INSTALL_STATE[61]} == 1 ))
		then
			# Enable WiFi modules
			/boot/dietpi/func/dietpi-set_hardware wifimodules enable

			while :
			do
				local criteria_passed=1
				local output_string='The following criteria must be met for the installation of WiFi Hotspot to succeed:'

				if [[ $(G_GET_NET -q -t eth ip) ]]
				then
					output_string+='\n\n - Ethernet online: PASSED'
				else
					criteria_passed=0
					output_string+='\n\n - Ethernet online: FAILED.\nUse dietpi-config to connect and configure Ethernet.'
				fi

				if [[ $(G_GET_NET -q -t wlan iface) ]]
				then
					output_string+='\n\n - WiFi adapter detected: PASSED'
				else
					criteria_passed=0
					output_string+='\n\n - WiFi adapter detected: FAILED.\nPlease connect a WiFi adapter and try again.'
				fi

				# Passed
				if (( $criteria_passed ))
				then
					output_string+='\n\nPASSED: Criteria met. Good to go.'
					G_WHIP_MSG "$output_string"
					break

				# Failed, retry?
				else
					output_string+='\n\nFAILED: Criteria not met. Would you like to check again?'
					G_WHIP_YESNO "$output_string" && continue

					(( ${aSOFTWARE_INSTALL_STATE[60]} == 1 )) && aSOFTWARE_INSTALL_STATE[60]=0
					(( ${aSOFTWARE_INSTALL_STATE[61]} == 1 )) && aSOFTWARE_INSTALL_STATE[61]=0
					G_WHIP_MSG 'WiFi Hotspot criteria were not met. The software will not be installed.'
					break
				fi
			done
		fi

		# Let's Encrypt
		(( ${aSOFTWARE_INSTALL_STATE[92]} == 1 )) && G_WHIP_MSG 'The DietPi installation of Certbot supports all offered web servers.\n\nOnce the installation has finished, you can setup your free SSL cert with:
 - DietPi-LetsEncrypt\n\nThis is an easy to use frontend for Certbot and allows integration into DietPi systems.\n\nMore information:\n - https://dietpi.com/docs/software/system_security/#lets-encrypt'

		# Steam on ARMv7 via Box86 warning
		(( ${aSOFTWARE_INSTALL_STATE[156]} == 1 && $G_HW_ARCH == 2 )) && G_WHIP_MSG '[WARNING] Steam natively only runs on the x86 systems.\n\nBox86 will be used to run it on ARM, however there may be performance and compatibility issues.'

		# Home Assistant: Inform about long install/build time: https://github.com/MichaIng/DietPi/issues/2897
		(( ${aSOFTWARE_INSTALL_STATE[157]} == 1 )) && G_WHIP_MSG '[ INFO ] Home Assistant: Grab yourself a coffee
\nThe install process of Home Assistant within the virtual environment, especially the Python build, can take more than one hour, especially on slower SBCs like RPi Zero and similar.
\nPlease be patient. In the meantime you may study the documentation:
 - https://dietpi.com/docs/software/home_automation/#home-assistant'
	}

	Menu_Main()
	{
		# Selected SSH server choice
		local sshserver_text='None'
		if (( ${aSOFTWARE_INSTALL_STATE[104]} > 0 )); then

			sshserver_text=${aSOFTWARE_NAME[104]} # Dropbear

		elif (( ${aSOFTWARE_INSTALL_STATE[105]} > 0 )); then

			sshserver_text=${aSOFTWARE_NAME[105]} # OpenSSH

		fi

		# Selected logging system choice
		local index_logging_text='None'
		if (( $INDEX_LOGGING == -1 )); then

			index_logging_text='DietPi-RAMlog #1'

		elif (( $INDEX_LOGGING == -2 )); then

			index_logging_text='DietPi-RAMlog #2'

		elif (( $INDEX_LOGGING == -3 )); then

			index_logging_text='Full'

		fi

		# Get real userdata location
		local user_data_location_current=$(readlink -f /mnt/dietpi_userdata)

		local user_data_location_description="Custom | $user_data_location_current"
		if [[ $user_data_location_current == '/mnt/dietpi_userdata' ]]; then

			user_data_location_description="SD/eMMC | $user_data_location_current"

		elif [[ $user_data_location_current == "$(findmnt -Ufnro TARGET -S /dev/sda1)" ]]; then

			user_data_location_description="USB Drive | $user_data_location_current"

		fi

		# Software to be installed or removed based on choice system
		local tobeinstalled_text toberemoved_text

		G_WHIP_MENU_ARRAY=(

			'Help!' ': Links to online guides, docs and information'
			'DietPi-Config' ': Feature-rich configuration tool for your device'
			'' '●─ Select Software '
			'Search Software' ': Find software to install via search box'
			'Browse Software' ': Select software from the full list'
			'SSH Server' ": [$sshserver_text]"
			'Log System' ": [$index_logging_text]"
			'User Data Location' ": [$user_data_location_description]"
			'' '●─ Install or Remove Software '
			'Uninstall' ': Select installed software for removal'
			'Install' ': Go >> Start installation for selected software'
		)

		G_WHIP_DEFAULT_ITEM=$MENU_MAIN_LASTITEM
		G_WHIP_BUTTON_CANCEL_TEXT='Exit'
		G_WHIP_SIZE_X_MAX=80
		if G_WHIP_MENU; then

			MENU_MAIN_LASTITEM=$G_WHIP_RETURNED_VALUE

			case "$G_WHIP_RETURNED_VALUE" in

				'Uninstall') Menu_Uninstall_Software;;

				'Search Software') Menu_CreateSoftwareList search;;

				'Browse Software') Menu_CreateSoftwareList;;

				'SSH Server')

					G_WHIP_MENU_ARRAY=(

						'None' ': Not required / manual setup'
						"${aSOFTWARE_NAME[104]}" ": ${aSOFTWARE_DESC[104]} (recommended)"
						"${aSOFTWARE_NAME[105]}" ": ${aSOFTWARE_DESC[105]}"
					)

					G_WHIP_DEFAULT_ITEM=$sshserver_text
					G_WHIP_BUTTON_CANCEL_TEXT='Back'
					G_WHIP_MENU 'Please select desired SSH server:
\n- None: Selecting this option will uninstall all SSH servers. This reduces system resources and improves performance. Useful for users who do NOT require networked/remote terminal access.
\n- Dropbear (recommended): Lightweight SSH server, installed by default on DietPi systems.
\n- OpenSSH: A feature-rich SSH server with SFTP/SCP support, at the cost of increased resource usage.' || return 0

					# Apply selection
					case "$G_WHIP_RETURNED_VALUE" in

						'None') Apply_SSHServer_Choices 0;;
						"${aSOFTWARE_NAME[105]}") Apply_SSHServer_Choices -2;;
						*) Apply_SSHServer_Choices -1;;
					esac

					# Check for changes
					for i in 104 105
					do
						(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && tobeinstalled_text+="\n - ${aSOFTWARE_NAME[$i]}"
						(( ${aSOFTWARE_INSTALL_STATE[$i]} == -1 )) && toberemoved_text+="\n - ${aSOFTWARE_NAME[$i]}"
					done
					[[ $tobeinstalled_text || $toberemoved_text ]] || return 0
					[[ $tobeinstalled_text ]] && tobeinstalled_text="\n\nThe following software will be installed:$tobeinstalled_text"
					[[ $toberemoved_text ]] && toberemoved_text="\n\nThe following software will be uninstalled:$toberemoved_text"

					G_WHIP_MSG "$G_WHIP_RETURNED_VALUE has been selected:\n- Your choice will be applied when 'Install Go >> Start installation' is selected.$tobeinstalled_text$toberemoved_text"
				;;

				'Log System')

					G_WHIP_MENU_ARRAY=(

						'None' ': Not required / manual setup'
						'DietPi-RAMlog #1' ': Hourly clear (recommended)'
						'DietPi-RAMlog #2' ': Hourly save, then clear'
						'Full' ': Logrotate and Rsyslog'
					)

					G_WHIP_DEFAULT_ITEM=$index_logging_text
					G_WHIP_BUTTON_CANCEL_TEXT='Back'
					G_WHIP_MENU 'Please select desired logging system:
\n- None: Selecting this option will uninstall DietPi-RAMlog, Logrotate and Rsyslog.
\n- DietPi-RAMlog #1 (Max performance): Mounts /var/log to RAM, reducing filesystem I/O. Logfiles are cleared every hour. Does NOT save logfiles to disk.
\n- DietPi-RAMlog #2: Same as #1, with the added feature of appending logfile contents to disk at /root/logfile_storage, before being cleared.
\n- Full (Reduces performance): Leaves /var/log on DISK, reduces SD card lifespan. Full logging system with Logrotate and Rsyslog.' || return 0

					# Apply selection
					case "$G_WHIP_RETURNED_VALUE" in

						'None') Apply_Logging_Choices 0;;
						'DietPi-RAMlog #2') Apply_Logging_Choices -2;;
						'Full') Apply_Logging_Choices -3;;
						*) Apply_Logging_Choices -1;;
					esac

					# Check for changes
					for i in 101 102 103
					do
						(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && tobeinstalled_text+="\n - ${aSOFTWARE_NAME[$i]}"
						(( ${aSOFTWARE_INSTALL_STATE[$i]} == -1 )) && toberemoved_text+="\n - ${aSOFTWARE_NAME[$i]}"
					done
					[[ $tobeinstalled_text || $toberemoved_text ]] || return 0
					[[ $tobeinstalled_text ]] && tobeinstalled_text="\n\nThe following software will be installed:$tobeinstalled_text"
					[[ $toberemoved_text ]] && toberemoved_text="\n\nThe following software will be uninstalled:$toberemoved_text"

					G_WHIP_MSG "$G_WHIP_RETURNED_VALUE has been selected:\n- Your choice will be applied when 'Install : Go >> Start installation' is selected.$tobeinstalled_text$toberemoved_text"
				;;

				'User Data Location')

					# - Vars if we need to move data.
					local move_data_target=$user_data_location_current

					G_WHIP_MENU_ARRAY=(

						'List' ': Select from a list of available drives to move user data.'
						'Custom' ': Manually enter a location to move user data.'
						'Drive' ': Launch DietPi-Drive_Manager.'
					)

					G_WHIP_BUTTON_CANCEL_TEXT='Back'
					G_WHIP_MENU 'Choose where to store your user data. User data includes software such as ownCloud data store, BitTorrent downloads etc.
\nMore information on user data in DietPi:\n- https://dietpi.com/docs/dietpi_tools/#quick-selections
\n- DietPi-Drive_Manager: Launch DietPi-Drive_Manager to setup external drives, and, move user data to different locations.' || return 0

					# Launch DietPi-Drive_Manager
					if [[ $G_WHIP_RETURNED_VALUE == 'Drive' ]]; then

						/boot/dietpi/dietpi-drive_manager
						return 0

					# List
					elif [[ $G_WHIP_RETURNED_VALUE == 'List' ]]; then

						/boot/dietpi/dietpi-drive_manager 1 || return 1

						local return_value=$(</tmp/dietpi-drive_manager_selmnt)
						[[ $return_value ]] || return 1

						[[ $return_value == '/' ]] && return_value='/mnt'
						move_data_target=$return_value
						move_data_target+='/dietpi_userdata'

					# Manual file path entry
					elif [[ $G_WHIP_RETURNED_VALUE == 'Custom' ]]; then

						G_WHIP_INPUTBOX 'Please input a location. Your user data will be stored inside this location.\n - eg: /mnt/MyDrive/MyData' || return 1
						move_data_target=$G_WHIP_RETURNED_VALUE

					fi

					# Move data if the new entry has changed
					[[ $user_data_location_current != "$move_data_target" ]] || return 0

					# Ask before we begin
					G_WHIP_YESNO "DietPi will now attempt to transfer your existing user data to the new location:
\n- From: $user_data_location_current\n- To: $move_data_target\n\nWould you like to begin?" || return 0

					# Move data, setup symlinks
					if /boot/dietpi/func/dietpi-set_userdata "$user_data_location_current" "$move_data_target"; then

						G_WHIP_MSG "User data transfer: Completed\n\nYour user data has been successfully moved:\n\n- From: $user_data_location_current\n- To: $move_data_target"

					else

						G_WHIP_MSG "User data transfer: Failed\n\n$(</var/log/dietpi-move_userdata.log)\n\nNo changes have been applied."

					fi
				;;

				'DietPi-Config') /boot/dietpi/dietpi-config;;

				'Help!')

					local string='───────────────────────────────────────────────────────────────
Welcome to DietPi:
───────────────────────────────────────────────────────────────
Use PageUp/Down or Arrow Up/Down to scroll this help screen.
Press ESC, or TAB then ENTER to exit this help screen.\n
Easy to follow, step by step guides for installing DietPi:
https://dietpi.com/docs/install/\n
For a list of all installation options and their details:
https://dietpi.com/docs/software/\n
───────────────────────────────────────────────────────────────
List of installed software and their online documentation URLs:
───────────────────────────────────────────────────────────────\n'

					# Installed software
					for i in "${!aSOFTWARE_NAME[@]}"
					do
						[[ ${aSOFTWARE_INSTALL_STATE[i]} -gt 0 && ${aSOFTWARE_DOCS[$i]} ]] || continue
						string+="\n${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}\n${aSOFTWARE_DOCS[$i]}\n"
					done

					G_WHIP_SIZE_X_MAX=70
					G_WHIP_MSG "$string"
				;;

				'Install') Menu_StartInstall;;

				*) :;;

			esac

		# Exit/Abort Setup
		else
			Menu_Exit
		fi
	}

	Menu_Exit()
	{
		TARGETMENUID=0 # Return to Main Menu

		# Standard exit
		if (( $G_DIETPI_INSTALL_STAGE == 2 )); then

			G_WHIP_YESNO 'Do you wish to exit DietPi-Software?\n\nAll changes to software selections will be cleared.' || return 0
			exit 0

		fi

		# Prevent exit on 1st run setup
		G_WHIP_MSG 'DietPi has not fully been installed.\nThis must be completed prior to using DietPi by selecting:\n - Go Start Install.'
	}

	Menu_StartInstall()
	{
		local tobeinstalled_text toberemoved_text summary_text

		# Obtain list of pending software installs and uninstalls
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 1 )) && tobeinstalled_text+="\n - ${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}"
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == -1 )) && toberemoved_text+="\n - ${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}"
		done

		# Check if user made/changed software selections
		if [[ $tobeinstalled_text || $toberemoved_text ]]; then

			# List selections and ask for confirmation
			[[ $tobeinstalled_text ]] && tobeinstalled_text="\n\nThe following software will be installed:$tobeinstalled_text"
			[[ $toberemoved_text ]] && toberemoved_text="\n\nThe following software will be uninstalled:$toberemoved_text"
			[[ $G_SERVICE_CONTROL == 0 ]] || summary_text='\n\nNB: Software services will be temporarily controlled (stopped) by DietPi during this process. Please inform connected users, before continuing. SSH and VNC are not affected.'

			G_WHIP_YESNO "DietPi is now ready to apply your software choices:$tobeinstalled_text$toberemoved_text$summary_text
\nSoftware details, usernames, passwords etc:\n - https://dietpi.com/docs/software/\n\nWould you like to begin?" || return 0

			# If due to choice changes only uninstalls are done and it is not the first run setup, skip the install function and call the uninstall function directly.
			if [[ $G_DIETPI_INSTALL_STAGE == 2 && ! $tobeinstalled_text ]]
			then
				Uninstall_Software
				Write_InstallFileList
			else
				GOSTARTINSTALL=1 # Set install start flag
			fi
			TARGETMENUID=-1 # Exit menu loop

		# After first run setup has finished, abort install without any selections
		elif (( $G_DIETPI_INSTALL_STAGE == 2 )); then

			G_WHIP_MSG 'No changes have been detected. Unable to start installation.'

		# Allow to finish first run setup without any selections
		else

			G_WHIP_YESNO 'DietPi was unable to detect any additional software selections for install.
\nNB: You can use dietpi-software at a later date, to install optimised software from our catalogue as required.
\nDo you wish to continue with DietPi as a pure minimal image?' || return 0

			TARGETMENUID=-1 # Exit menu loop
			GOSTARTINSTALL=1 # Set install start flag

		fi
	}

	Menu_Uninstall_Software()
	{
		# Array which will hold all software IDs to be removed.
		G_WHIP_CHECKLIST_ARRAY=()

		# Obtain list of installed software
		local i
		for i in "${!aSOFTWARE_NAME[@]}"
		do
			(( ${aSOFTWARE_INSTALL_STATE[$i]} == 2 )) || continue
			# Skip webserver stacks: Their install states will be aligned with webserver/database install states automatically.
			[[ $i =~ ^(75|76|78|79|81|82)$ ]] || G_WHIP_CHECKLIST_ARRAY+=("$i" "${aSOFTWARE_NAME[$i]}: ${aSOFTWARE_DESC[$i]}" 'off')
		done

		# No software installed
		if (( ! ${#G_WHIP_CHECKLIST_ARRAY[@]} )); then

			G_WHIP_MSG 'No software is currently installed.'

		# Run menu
		else

			G_WHIP_BUTTON_CANCEL_TEXT='Back'
			G_WHIP_CHECKLIST 'Use the spacebar to select the software you would like to remove:' && [[ $G_WHIP_RETURNED_VALUE ]] || return 0

			# Create list for user to review before removal
			local output_string='The following software will be REMOVED from your system:'
			for i in $G_WHIP_RETURNED_VALUE
			do
				output_string+="\n - ${aSOFTWARE_NAME[$i]} (ID=$i): ${aSOFTWARE_DESC[$i]}"
			done

			G_WHIP_YESNO "$output_string
\nNB: Uninstalling usually PURGES any related userdata and configs. If you only need to repair or update software, please use \"dietpi-software reinstall <ID>\" instead.
\nDo you wish to continue?" || return 0

			# Mark for uninstall
			for i in $G_WHIP_RETURNED_VALUE
			do
				aSOFTWARE_INSTALL_STATE[$i]=-1
			done

			# Run uninstall
			Uninstall_Software

			# Save install states
			Write_InstallFileList

			G_WHIP_MSG 'Uninstall completed'

		fi
	}

	#/////////////////////////////////////////////////////////////////////////////////////
	# Main Loop
	#/////////////////////////////////////////////////////////////////////////////////////
	# Abort if a reboot is required as of missing kernel modules
	if (( $G_DIETPI_INSTALL_STAGE == 2 )) && ! G_CHECK_KERNEL
	then
		G_WHIP_BUTTON_CANCEL_TEXT='Abort' G_WHIP_YESNO "[ INFO ] A reboot is required
\nKernel modules for the loaded kernel at /lib/modules/$(uname -r) are missing. This is most likely the case as of a recently applied kernel upgrade where a reboot is required to load the new kernel.
\nTo assure that $G_PROGRAM_NAME can run successfully, especially when performing installs, it is required that you perform a reboot so that kernel modules can be loaded ondemand.
\nThere may be rare cases where no dedicated kernel modules are used but all require modules are builtin. If this is the case, please create the mentioned directory manually to proceed.
\nDo you want to reboot now?" && reboot || exit 1
	fi
	# Init software arrays
	Software_Arrays_Init
	#-------------------------------------------------------------------------------------
	# Load .installed file, update vars, if it exists
	Read_InstallFileList
	#-------------------------------------------------------------------------------------
	# CLI input mode: Force menu mode on first run
	if [[ $1 && $G_DIETPI_INSTALL_STAGE == 2 ]]
	then
		Input_Modes "$@"

	#-------------------------------------------------------------------------------------
	# Standard launch
	else
		# DietPi-Automation pre install steps
		(( $G_DIETPI_INSTALL_STAGE == 2 )) || DietPi-Automation_Pre

		# Start DietPi Menu
		until (( $TARGETMENUID < 0 ))
		do
			G_TERM_CLEAR
			Menu_Main
		done
	fi
	#-------------------------------------------------------------------------------------
	# Start DietPi-Software installs
	(( $GOSTARTINSTALL )) || exit 0

	# Userdata location verify
	G_CHECK_USERDATA

	# Start software installs
	Run_Installations

	# DietPi-Automation post install steps
	(( $G_DIETPI_INSTALL_STAGE == 2 )) || DietPi-Automation_Post

	G_DIETPI-NOTIFY 3 "$G_PROGRAM_NAME" 'Install completed'

	# Upload DietPi-Survey data if opted in, prompt user choice if no settings file exists
	# - Skip if G_SERVICE_CONTROL == 0, exported by "patches" (DietPi-Update) which sends survey already
	# Start services, restart to reload configs of possibly running services
	if [[ $G_SERVICE_CONTROL != 0 ]]
	then
		/boot/dietpi/dietpi-survey 1
		/boot/dietpi/dietpi-services restart
		(( $RESTART_DELUGE_WEB )) && { G_SLEEP 1; G_EXEC_NOHALT=1 G_EXEC systemctl restart deluge-web; }
	fi

	# Start installed services, not controlled by DietPi-Services
	[[ ${aSTART_SERVICES[0]} ]] || exit 0

	G_DIETPI-NOTIFY 2 'Starting installed services not controlled by DietPi-Services'
	for i in "${aSTART_SERVICES[@]}"
	do
		G_EXEC_NOHALT=1 G_EXEC systemctl start "$i"
	done
	#-------------------------------------------------------------------------------------
	exit 0
	#-------------------------------------------------------------------------------------
}
