#!/bin/bash
#
# Once per day, run the sendPeriodicSummaryToUsers admin task
# Prevents duplicate executions when running on load-balanced containers
# Bradley Logan <bradley.logan@rhisac.org>
#
# 2022/11/28 - Created
#

# Grab environment variables
for variable_value in $(sed 's/\x00/\n/g' < /proc/1/environ); do
    export $variable_value
done

task_name="sendPeriodicSummaryToUsers"
today=$(date +%F)
echo "Determining if task $task_name should be executed"

last_run=$(mysql -u $MYSQL_USER --password="$MYSQL_PASSWORD" -h $MYSQL_HOST -P 3306 $MYSQL_DATABASE -s -N -e "LOCK TABLES periodic_tasks WRITE, periodic_tasks AS pt1 READ,periodic_tasks AS pt2 READ;SELECT last_run FROM periodic_tasks WHERE task_name = '$task_name';REPLACE INTO periodic_tasks (task_name, last_run) SELECT '$task_name' AS task_name, IF((SELECT COUNT(*) FROM periodic_tasks AS pt1 WHERE DATE(last_run) = DATE('$today') AND task_name = '$task_name') < 1, now(), (SELECT last_run FROM periodic_tasks AS pt2 WHERE task_name = '$task_name')) AS last_run;UNLOCK TABLES;")

if [ $? -eq 0 ]; then
    last_date=$(echo $last_run | cut -f1 -d " ")
    if [ "$last_date" = "$today" ]; then
        echo "Task was already run today: $last_run UTC"
        echo "Exiting..."
    else
        echo "Task has not yet been run today. Last run: $last_run UTC"
        echo "Executing task..."
        /var/www/MISP/app/Console/cake Server sendPeriodicSummaryToUsers
    fi
else
    echo "ERROR: Failed to retrieve last run timestamp and/or update table"
fi