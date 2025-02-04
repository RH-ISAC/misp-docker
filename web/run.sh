#!/bin/bash
#
# MISP docker startup script
# Xavier Mertens <xavier@rootshell.be>
# Steven Goossens <steven@teamg.be>
#
# 2017/05/17 - Created
# 2017/05/31 - Fixed small errors
# 2019/10/17 - Use built-in mysql docker DB creation and use std env names (dafal)
# 2021/03/09 - Update to work with the install script provided by MISP. Includes https support, Python venv,...
#

set -e

if [ -r /.firstboot.tmp ]; then
        echo "Container started for the fist time. Setup might time a few minutes. Please wait..."
        echo "(Details are logged in /tmp/install.log)"
        export DEBIAN_FRONTEND=noninteractive

        # If the user uses a mount point restore our files
        if [ ! -d /var/www/MISP/app ]; then
                echo "Restoring MISP files..."
                cd /var/www/MISP
                tar xzpf /root/MISP.tgz
                rm /root/MISP.tgz
        fi

        echo "Configuring postfix"
        if [ -z "$POSTFIX_RELAY_HOST" ]; then
                echo "POSTFIX_RELAY_HOST is not set, please configure Postfix manually later..."
        else
                postconf -e "relayhost = $POSTFIX_RELAY_HOST"

                # Relay Host Auth
                if [ -z "$POSTFIX_USERNAME" ] || [ -z $POSTFIX_PASSWORD ]; then
                        echo "POSTFIX_USERNAME and/or POSTFIX_PASSWORD not set, no auth configured..."
                else
                        echo "$POSTFIX_RELAY_HOST  $POSTFIX_USERNAME:$POSTFIX_PASSWORD" > /etc/postfix/sasl_passwd
                        postmap /etc/postfix/sasl_passwd
                        rm /etc/postfix/sasl_passwd
                        postconf -e "smtp_use_tls = yes"
                        postconf -e "smtp_sasl_auth_enable = yes"
                        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
                        postconf -e "smtp_sasl_security_options = noanonymous"
                        postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
                fi
                # RHISAC Environment
                postconf -e "inet_protocols = ipv4"
        fi

        # Fix timezone (adapt to your local zone)
        if [ -z "$TIMEZONE" ]; then
                echo "TIMEZONE is not set, please configure the local time zone manually later..."
        else
                echo "$TIMEZONE" > /etc/timezone
                dpkg-reconfigure -f noninteractive tzdata >>/tmp/install.log
        fi

        echo "Creating MySQL database"

        # Check MYSQL_HOST
        if [ -z "$MYSQL_HOST" ]; then
                echo "MYSQL_HOST is not set. Aborting."
                exit 1
        fi
		
		# Waiting for DB to be ready
		while ! mysqladmin ping -h"$MYSQL_HOST" --silent; do
		    sleep 5
			echo "Waiting for database to be ready..."
		done
		
        # Set MYSQL_PASSWORD
        if [ -z "$MYSQL_PASSWORD" ]; then
                echo "MYSQL_PASSWORD is not set, use default value '<REDACTED>'"
                MYSQL_PASSWORD=misp
        else
                echo "MYSQL_PASSWORD is set to '<REDACTED>'"
        fi

        ret=`echo 'SHOW TABLES;' | mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_HOST -P 3306 $MYSQL_DATABASE # 2>&1`
        if [ $? -eq 0 ]; then
                echo "Connected to database successfully!"
                found=0
                for table in $ret; do
                        if [ "$table" == "attributes" ]; then
                                found=1
                        fi
                done
                if [ $found -eq 1 ]; then
                        echo "Database misp available"
                else
                        echo "Database misp empty, creating tables ..."
                        ret=`mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" $MYSQL_DATABASE -h $MYSQL_HOST -P 3306 2>&1 < /var/www/MISP/INSTALL/MYSQL.sql`
                        if [ $? -eq 0 ]; then
                            echo "Imported /var/www/MISP/INSTALL/MYSQL.sql successfully"
                        else
                            echo "ERROR: Importing /var/www/MISP/INSTALL/MYSQL.sql failed:"
                            echo $ret
                        fi
                fi
        else
                echo "ERROR: Connecting to database failed:"
                echo $ret
        fi

        # Create database table to track execution of periodic tasks across multiple container instances
        query="CREATE TABLE IF NOT EXISTS periodic_tasks (task_name varchar(255), last_run datetime(0), PRIMARY KEY (task_name));"
        mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_HOST -P 3306 $MYSQL_DATABASE -s -e "$query"
        if [ $? -eq 0 ]; then
                echo "Successfully created periodic_tasks DB table if didn't exist already"
        else
                echo "ERROR: Failed to create periodic_tasks DB table"
        fi

        # MISP configuration
        echo "Creating MISP configuration files"
        cd /var/www/MISP/app/Config
	cp -a database.default.php database.php
        sed -i "s/'database' => 'misp'/'database' => '$MYSQL_DATABASE'/" database.php
	sed -i "s/localhost/$MYSQL_HOST/" database.php
        sed -i "s/db\s*login/$MYSQL_USER/" database.php
        sed -i "s/8889/3306/" database.php
        sed -i "s/db\s*password/$MYSQL_PASSWORD/" database.php

        # Use DB for MISP Session Handler
        sed -z -i "s;'Session', array(\n\t'timeout'        => 60,    // Session timeout, default is 1 hour\n\t'cookie_timeout' => 10080 ,  // Cookie timeout, default is 1 week\n\t'defaults'       => 'php',;'Session', array(\n\t'timeout'        => 60,    // Session timeout, default is 1 hour\n\t'cookie_timeout' => 10080,  // Cookie timeout, default is 1 week\n\t'defaults'       => 'database',;" core.php

        # Fix the base url
        if [ -z "$MISP_BASEURL" ]; then
                echo "No base URL defined, don't forget to define it manually!"
        else
                echo "Fixing the MISP base URL ($MISP_BASEURL) ..."
                /var/www/MISP/app/Console/cake Admin setSetting "MISP.baseurl" "$MISP_BASEURL"
                sed -i "s@'rest_client_baseurl'[\t ]*=>[\t ]*'.*',@'rest_client_baseurl' => '$MISP_BASEURL',@g" /var/www/MISP/app/Config/config.php
        fi
		
		#Redis should not run as a daemon
		sed -i "s/daemonize yes/daemonize no/g" /etc/redis/redis.conf

        # Set MISP instance sender email
        if [ -z "$MISP_INSTANCE_EMAIL" ]; then
                echo "No instance email defined!"
        else
                echo "Setting the MISP instance email ($MISP_INSTANCE_EMAIL) ..."
                /var/www/MISP/app/Console/cake Admin setSetting "MISP.email" "$MISP_INSTANCE_EMAIL"
        fi
	
        # Update DB with latest Galaxies, Noticelists, Warninglists,
        # Taxonomies, ObjectTemplates, and ObjectRelationships
        /var/www/MISP/app/Console/cake Admin updateJSON
        
        # Ensure postfix was started properly
        service postfix restart
        
        # Display tips
        cat <<__WELCOME__
Congratulations!
Your MISP docker has been successfully booted for the first time.
Don't forget:
- Reconfigure postfix to match your environment
- Change the MISP admin email address to $MISP_ADMIN_EMAIL

__WELCOME__

	#Add crontab to sync data from remote servers
	service cron start

	# Schedule periodic task "sendPeriodicSummaryToUsers" at 6am EST
	{ crontab -l 2>/dev/null || true; echo "0 11 * * * /usr/local/bin/run_sendPeriodicSummary_task.sh"; } | crontab -
	
	##Schedule to sync all servers every hour
	{ crontab -l 2>/dev/null || true; echo "0 * * * * /var/www/MISP/app/Console/cake Server pullAll 2 full"; } | crontab -
	
	##Schedule to fetch all feeds at 1 am
	{ crontab -l 2>/dev/null || true; echo "0 1 * * * /var/www/MISP/app/Console/cake Server fetchFeed 2 all"; } | crontab -
        rm -f /.firstboot.tmp
fi

# Make MISP live - this isn't ideal, as it means taking an instance
# non-live will make it live again if the container restarts.  That seems
# better than the default which is that MISP is non-live on container restart.
# Ideally live/non-live would be persisted in the database.
/var/www/MISP/app/Console/cake Admin setSetting "MISP.python_bin" "/var/www/MISP/venv/bin/python"
/var/www/MISP/app/Console/cake live 1
chown www-data:www-data /var/www/MISP/app/Config/config.php*
chmod o-rwx /var/www/MISP/app/Config/config.php*

# Start supervisord
echo "Starting supervisord"
cd /
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
          
