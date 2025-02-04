
FROM ubuntu:focal

# Install core components
ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get dist-upgrade -y && apt-get upgrade && apt-get autoremove -y && apt-get clean && \
    apt-get install -y software-properties-common && \
    apt-get install -y postfix && \
    apt-get install -y mysql-client curl gcc git gnupg-agent \
    make openssl redis-server sudo vim zip locales wget iproute2 supervisor cron

RUN add-apt-repository ppa:deadsnakes/ppa
RUN apt-get update && apt-get -y install python3.9 python3-pip
RUN pip3 install --upgrade pip


RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8

RUN useradd misp && usermod -aG sudo misp

# Install script
COPY --chown=misp:misp INSTALL_NODB.sh* ./
RUN chmod +x INSTALL_NODB.sh
RUN echo "ALL ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers


USER misp

RUN bash INSTALL_NODB.sh -A -u

USER root

RUN pip3 list -o | cut -f1 -d' ' | tr " " "\n" | awk '{if(NR>=3)print}' | cut -d' ' -f1 | xargs -n1 pip3 install -U ; exit 0 #Hack error code

# Re-install special MISP version of STIX2 that mispmodules likely overwrote
RUN . /var/www/MISP/venv/bin/activate && pip3 install -I /var/www/MISP/app/files/scripts/cti-python-stix2 && deactivate


# Supervisord Setup
RUN ( \
    echo '[supervisord]'; \
    echo 'nodaemon = true'; \
    echo ''; \
    echo '[program:postfix]'; \
    echo 'process_name = master'; \
    echo 'directory = /etc/postfix'; \
    echo 'command = /usr/sbin/postfix -c /etc/postfix start'; \
    echo 'startsecs = 0'; \
    echo 'autorestart = false'; \
    echo ''; \
    echo '[program:redis-server]'; \
    echo 'command=redis-server /etc/redis/redis.conf'; \
    echo 'user=redis'; \
    echo ''; \
    echo '[program:apache2]'; \
    echo 'command=/bin/bash -c "source /etc/apache2/envvars && exec /usr/sbin/apache2 -D FOREGROUND"'; \
    echo ''; \
    echo '[program:resque]'; \
    echo 'command=/bin/bash /var/www/MISP/app/Console/worker/start.sh'; \
    echo 'user=www-data'; \
    echo 'startsecs = 0'; \
    echo 'autorestart = false'; \
    echo 'redirect_stderr=true'; \
    echo 'stdout_logfile=/var/www/MISP/app/tmp/logs/resque-start.log'; \
    echo 'user=www-data'; \
    echo ''; \
    echo '[program:misp-modules]'; \
    echo 'command=/bin/bash -c "/var/www/MISP/venv/bin/misp-modules -l 127.0.0.1 -s"'; \
    echo 'startsecs = 0'; \
    echo 'autorestart = false'; \
    echo 'user=www-data'; \
    ) >> /etc/supervisor/conf.d/supervisord.conf

# Add run script
# Trigger to perform first boot operations
ADD run.sh /run.sh
# Ensure that wait for it is included in the path and executable
ADD wait-for-it.sh /usr/local/bin/wait-for-it.sh
RUN chmod +x /usr/local/bin/wait-for-it.sh
RUN mv /etc/apache2/sites-available/misp-ssl.conf /etc/apache2/sites-available/misp-ssl.conf.bak
ADD misp-ssl.conf /etc/apache2/sites-available/misp-ssl.conf
RUN chmod 0755 /run.sh && touch /.firstboot.tmp
# Make a backup of /var/www/MISP to restore it to the local moint point at first boot
WORKDIR /var/www/MISP
RUN tar czpf /root/MISP.tgz .

# Add script to handle execution of sendPeriodicSummaryToUsers
# periodic task across multiple container instances 
ADD run_sendPeriodicSummary_task.sh /usr/local/bin/run_sendPeriodicSummary_task.sh
RUN chmod +x /usr/local/bin/run_sendPeriodicSummary_task.sh

VOLUME /var/www/MISP
EXPOSE 80
ENTRYPOINT ["/run.sh"]
