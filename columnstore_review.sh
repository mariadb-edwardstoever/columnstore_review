#!/bin/bash
# columnstore_review.sh
# script by Edward Stoever for MariaDB support
VERSION=1.2.0

function prepare_for_run() {
  unset ERR
  OUTDIR=/tmp/columnstore_review
  mkdir -p $OUTDIR
  WARNFILE=$OUTDIR/cs_warnings.out
  if [ $EM_CHECK ]; then
    EMOUTDIR=/tmp/columnstore_review/em; mkdir -p $EMOUTDIR
    OUTPUTFILE=$EMOUTDIR/$(hostname)_cs_em_check.txt
  else
    OUTPUTFILE=$OUTDIR/$(hostname)_cs_review.txt
  fi
  touch $WARNFILE || ERR=true
  touch $OUTPUTFILE || ERR=true
  if [ $ERR ]; then
     ech0 'Cannot create temporary output. Exiting'; exit 1;
  fi
  truncate -s0 $WARNFILE
  truncate -s0 $OUTPUTFILE
}

function exists_mariadb_installed() {
  ls /usr/sbin/mariadbd 1>/dev/null 2>/dev/null || echo 'MariaDB Server is not installed.' >> $WARNFILE
}

function exists_columnstore_installed() {
  ls /usr/bin/mariadb-columnstore-start.sh 1>/dev/null 2>/dev/null && CS_INSTALLED=true || echo 'Mariadb-Columnstore is not installed.' >> $WARNFILE
}

function exists_cmapi_installed() {
  ls /usr/share/columnstore/cmapi 1>/dev/null 2>/dev/null && CMAPI_INSTALLED=true || echo 'Mariadb-Columnstore-cmapi is not installed.' >> $WARNFILE
}

function exists_cmapi_running() {
  if [[ "$(ps -ef | grep cmapi_server | grep -v "grep" |wc -l)" == "0" ]]; then echo 'Mariadb-Columnstore-cmapi is not running.' >> $WARNFILE; else CMAPI_CONNECT=true; fi
}

function exists_mariadbd_running() {
  if [[ "$(ps -ef | grep mariadbd | grep -v "grep" |wc -l)" == "0" ]]; then echo 'Mariadb Server is not running.' >> $WARNFILE; else MARIADB_RUNNING=true; fi
}

function exists_columnstore_running() {
  if [[ "$(ps -ef | grep -E "(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|StorageManager|controllernode|workernode)" | grep -v "grep"|wc -l)" == "0" ]]; then 
    echo 'There are no Mariadb-Columnstore processes running.' >> $WARNFILE; 
  else
    CS_RUNNING=true
  fi
}

function exists_iptables_rules() {
  if [ "$(id -u)" -eq 0 ] && [ $(which iptables 2>/dev/null) ]; then
    if [[ $(iptables -S | grep -v ACCEPT) ]]; then echo 'Iptables rules exist.' >> $WARNFILE; fi
  fi
}

function exists_ip6tables_rules() {
  if [ "$(id -u)" -eq 0 ] &&  [ $(which ip6tables 2>/dev/null) ]; then
    if [[ $(ip6tables -S | grep -v ACCEPT) ]]; then echo 'Ip6tables rules exist.' >> $WARNFILE; fi
  fi
}

function exists_zombie_processes() {
  ZOMBIES=$(ps -ef | grep "\<defunct\>" | grep -v 'grep' | wc -l)
  if [[ "$ZOMBIES" == "0" ]]; then return; fi
  if [[ "$ZOMBIES" == "1"  ]]; then echo "There is 1 zombie process." >> $WARNFILE; return; fi
  echo "There are $ZOMBIES zombie processes." >> $WARNFILE
}

function exists_https_proxy() {
  if [ $CMAPI_CONNECT ]; then
    mcspm1host=$(mcsGetConfig PMS1 IPaddr)
    if [[ "$(timeout 4 curl -v https://$mcspm1host:8640 2>&1 | grep proxy | wc -l)" != "0" ]]; then echo 'Https_proxy is configured.' >> $WARNFILE; fi
  else
    if [[ $(env| grep https_proxy) ]]; then echo 'Https_proxy is set.' >> $WARNFILE; fi
  fi
}

function exists_cmapi_cert_expired() {
  if [ ! $CMAPI_INSTALLED ]; then return; fi
  CERTFILE='/usr/share/columnstore/cmapi/cmapi_server/self-signed.crt'
  if [[ ! -f $CERTFILE  ]]; then echo "The certificate file $CERTFILE does not exist." >> $WARNFILE; return; fi
  certdate=$(date -d "$(openssl x509 -enddate -noout -in $CERTFILE | sed 's/.*=//')" +%s)
  nowdate=$(date +%s)
  if (($certdate<=$nowdate)); then echo "The certificate $CERTFILE for cmapi https is expired." >> $WARNFILE; fi
}

function exists_client_able_to_connect_with_socket() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$SUDO_USER" ]; then
      RUNAS="$(whoami) (sudo)"
    else 
      RUNAS="$(whoami)"
    fi
  else 
    RUNAS="$(whoami)"
  fi

  OUTP="Columnstore Review Script Version $VERSION. Script by Edward Stoever for MariaDB Support. Script started at: "
  HDR=$(mariadb -ABNe "select concat('$OUTP', now())" 2>/dev/null || echo "$OUTP$(date +'%Y-%m-%d %H:%M:%S - No DB connection.')")
  if [[ ! "$HDR" =~ .*"No DB connection".* ]]; then CAN_CONNECT=true; fi
  print_color "$HDR\n"
  ech0 "Run as $RUNAS."
  ech0
}

function exists_corefiles() {
COREFILE_DIR=/var/log/mariadb/columnstore/corefiles
COREFILE_COUNT=$(find $COREFILE_DIR -type f| wc -l)
  if [ "$COREFILE_COUNT" -gt "0" ]; then
    if [ "$COREFILE_COUNT" == "1" ]; then 
      echo "There is 1 file in the Columnstore Core file directory $COREFILE_DIR." >> $WARNFILE;
    else
      echo "There are $COREFILE_COUNT files in the Columnstore Core file directory $COREFILE_DIR." >> $WARNFILE;
    fi
  fi
}

function exists_errors_pushing_config() {
  MESSAGESFILE=$(find /var/log -name messages -type f | head -1)
  if [ $MESSAGESFILE ]; then
    PUSHING_ERRORS=$(grep -i "Got an unexpected error pushing new config to" $MESSAGESFILE |wc -l)
  fi
  
  if [ "$PUSHING_ERRORS" -gt "0" ]; then
    if [ "$PUSHING_ERRORS" == "1" ]; then
      echo "There is 1 error related to pushing new config to cmapi in $MESSAGESFILE." >> $WARNFILE;
    else
      echo "There are $PUSHING_ERRORS errors related to pushing new config to cmapi in $MESSAGESFILE." >> $WARNFILE;
    fi
  fi
}

function exists_columnstore_tmp_files_wrong_owner() {
  TMP_DIR=$(mcsGetConfig SystemConfig SystemTempFileDir)
  if [ -d $TMP_DIR ]; then
    DIR_OWNER=$(stat -c '%U' $TMP_DIR)
  else
    return # directory does not exist, so OK.
  fi
  if [ "$DIR_OWNER" != "mysql" ]; then echo "The directory $TMP_DIR is not owned by mysql. See MCOL-4866."  >> $WARNFILE; fi
}

function exists_selinux_not_disabled() {
  if [ $(which getenforce 2>/dev/null) ]; then
    SELINUX=$(getenforce 2>/dev/null);
    if [ ! -z $SELINUX ] && [ ! "$SELINUX" == "Disabled" ]; then echo "SELINUX status: $SELINUX" >> $WARNFILE;  fi
  fi
}

function exists_mysql_user_with_proper_uid() {
  MYSQL_UID=$(id -u mysql 2>/dev/null) || echo 'OS user mysql does not exist.' >> $WARNFILE;
  THIS_SYS_UID_MAX=$(grep SYS_UID_MAX /etc/login.defsx 2>/dev/null | awk '{print $2}')
  if ! [[ $THIS_SYS_UID_MAX =~ '^[0-9]+$' ]] ; then THIS_SYS_UID_MAX=999; fi
  if [ "$MYSQL_UID" -gt "$THIS_SYS_UID_MAX" ]; then echo 'OS user mysql has high UID number. See MCOL-5216.' >> $WARNFILE; fi
}

function exists_cs_error_log() {
  CS_ERR_LOG=/var/log/mariadb/columnstore/err.log
  if [ ! -f $CS_ERR_LOG ]; then echo "There is no columnstore error log file: $CS_ERR_LOG."  >> $WARNFILE; unset CS_ERR_LOG; fi
}

function exists_error_log() {
#  if [ ! $CAN_CONNECT ]; then return; fi
  set_log_error
  if [ ! $LOG_ERROR ]; then echo 'MariaDB Server log_error is not set.' >> $WARNFILE; return; fi
  if [ ! -f $LOG_ERROR ]; then echo 'MariaDB Server log_error is set but file is not found.' >> $WARNFILE; unset LOG_ERROR; fi
#  unset DATADIR FULL_PATH
}

function exists_querystats_enabled() {
   if [ ! $CS_INSTALLED ]; then return; fi
   MCSQUERYSTATS=$(mcsGetConfig QueryStats Enabled 2>&1)
  if [ "$MCSQUERYSTATS" == "Y" ]; then
    return;
  else
    echo "QueryStats Enabled = $MCSQUERYSTATS" >> $WARNFILE
  fi
}
  
function exists_diskbased_hashjoin() {
   if [ ! $CS_INSTALLED ]; then return; fi
   MCSHASHJOIN=$(mcsGetConfig HashJoin AllowDiskBasedJoin 2>&1)
  if [ "$MCSHASHJOIN" == "Y" ]; then
    return;
  else
    echo "HashJoin AllowDiskBasedJoin = $MCSHASHJOIN" >> $WARNFILE
  fi
}

function exists_crossenginesupport() {
  if [ ! $CS_INSTALLED ]; then return; fi
  CROSSENGINE_HOST=$(mcsGetConfig CrossEngineSupport Host)
  CROSSENGINE_PORT=$(mcsGetConfig CrossEngineSupport Port)
  CROSSENGINE_USER=$(mcsGetConfig CrossEngineSupport User)
  CROSSENGINE_PW=$(mcsGetConfig CrossEngineSupport Password)
  if [ -z $CROSSENGINE_HOST ]; then NOTCROSSENGINESUPPORT=true; fi
  if [ -z $CROSSENGINE_PORT ]; then NOTCROSSENGINESUPPORT=true; fi
  if [ -z $CROSSENGINE_USER ]; then NOTCROSSENGINESUPPORT=true; fi
  if [ -z $CROSSENGINE_PW ]; then NOTCROSSENGINESUPPORT=true; fi

  if [ $NOTCROSSENGINESUPPORT ]; then 
    echo "CrossEngineSupport is not enabled." >> $WARNFILE
  fi
}

function exists_minimal_columnstore_running() {
  if [ ! $CS_RUNNING ]; then return; fi
  CONTROLLERNODEPID=$(pidof /usr/bin/controllernode)
  WORKERNODEPID=$(pidof /usr/bin/workernode)
  PRIMPROCPID=$(pidof /usr/bin/PrimProc)
  WRITEENGINESERVERPID=$(pidof /usr/bin/WriteEngineServer)
  DMLPROCPID=$(pidof /usr/bin/DMLProc)
  DDLPROCPID=$(pidof /usr/bin/DDLProc)
  EXEMGRPID=$(pidof /usr/bin/ExeMgr)
  if [ $CAN_CONNECT ]; then
    ISTWENTYSOMETHING=$(mariadb -ABNe "show global status like 'Columnstore_version';" | awk '{print $2}'| awk '{print substr ($0, 0, 2)}')
    if [[ ! "$ISTWENTYSOMETHING" =~ ^[2][2-9]$ ]]; then # version is not in the twenties
       if [ -z $EXEMGRPID ]; then echo "Columnstore processes running but ExeMgr process is not." >> $WARNFILE; fi
    fi
  fi
  if [ -z $WORKERNODEPID ]; then echo "Columnstore processes running but workernode process is not." >> $WARNFILE; fi
  if [ -z $PRIMPROCPID ]; then echo "Columnstore processes running but PrimProc process is not." >> $WARNFILE; fi
  if [ -z $WRITEENGINESERVERPID ]; then echo "Columnstore processes running but WriteEngineServer process is not." >> $WARNFILE; fi
  if [ $CONTROLLERNODEPID ]; then
    if [ -z $DMLPROCPID ]; then echo "Columnstore processes running but DMLProc process is not." >> $WARNFILE; fi
    if [ -z $DDLPROCPID ]; then echo "Columnstore processes running but DDLProc process is not." >> $WARNFILE; fi
  fi
}

function exists_history_of_delete_dml() {
   DELETES_FOUND=$(find /var/log/mariadb/columnstore/ -name "debug.log*" ! -name "*gz" |xargs grep dmlpackageproc|grep 'Start SQL statement' |grep -i delete |wc -l)
   if [ ! $DELETES_FOUND == "0" ]; then
      if [ $DELETES_FOUND == "1" ]; then
        echo "There is 1 DML delete found in recent logs." >> $WARNFILE
	  else
        DELETES_FOUND=$(printf "%'d" $DELETES_FOUND)
        echo "There are $DELETES_FOUND DML deletes found in recent logs." >> $WARNFILE
	  fi
   fi
}


function exists_history_of_update_dml() {
   UPDATES_FOUND=$(find /var/log/mariadb/columnstore/ -name "debug.log*" ! -name "*gz" |xargs grep dmlpackageproc|grep 'Start SQL statement' |grep -i update |wc -l)
   if [ ! $UPDATES_FOUND == "0" ]; then
      if [ $UPDATES_FOUND == "1" ]; then
        echo "There is 1 DML update found in recent logs." >> $WARNFILE
	  else
        UPDATES_FOUND=$(printf "%'d" $UPDATES_FOUND)
        echo "There are $UPDATES_FOUND DML updates found in recent logs." >> $WARNFILE
	  fi
   fi
}

function exists_history_of_file_does_not_exist() {
   FILE_DOES_NOT_EXIST=$(find /var/log/mariadb/columnstore/ -name "debug.log*" ! -name "*gz" | xargs grep 'Data file does not exist' | wc -l)
   if [ ! $FILE_DOES_NOT_EXIST == "0" ]; then
     echo "Errors found in debug logs: file does not exist. Run an extent map check." >> $WARNFILE
   fi
}

function exists_compression_header_errors() {
   ERROR_READING=$(find /var/log/mariadb/columnstore/ -name "crit.log*" ! -name "*gz" | xargs grep 'Error reading compression header' | wc -l)
   if [ ! $ERROR_READING == "0" ]; then
     echo "Errors found in crit logs: reading compression header. Check for possible data file corruption." >> $WARNFILE
   fi
}

function exists_history_failed_getSystemState() {
   FAILED_GETSYSTEMSTATE=$(find /var/log/mariadb/columnstore/ -name "debug.log*" ! -name "*gz" | xargs grep 'SessionManager::getSystemState() failed (network)' | wc -l)
   if [ ! $FAILED_GETSYSTEMSTATE == "0" ]; then
     echo "Errors found in debug logs: getSystemState failed. MariaDB and Columnstore may not be communicating." >> $WARNFILE
   fi
}

function exists_error_opening_file() {
   ERROR_OPENING=$(find /var/log/mariadb/columnstore/ -name "crit.log*" ! -name "*gz" | xargs grep 'Error opening file' | wc -l)
   if [ ! $ERROR_OPENING == "0" ]; then
     echo "Errors found in crit logs: opening file. Check for possible file permission and/or ownership problems." >> $WARNFILE
   fi
}

function exists_readtomagic_errors() {
   READTOMAGIC=$(find /var/log/mariadb/columnstore/ -name "crit.log*" ! -name "*gz" | xargs grep 'readToMagic' | wc -l)
   if [ ! $READTOMAGIC == "0" ]; then
     echo "Errors found in crit logs: readToMagic. Most readToMagic errors are inconsequential." >> $WARNFILE
   fi
}

function exists_bad_magic_errors() {
   BADMAGIC=$(find /var/log/mariadb/columnstore/ -name "crit.log*" ! -name "*gz" | xargs grep 'Bad magic' | wc -l)
   if [ ! $BADMAGIC == "0" ]; then
     echo "Errors found in crit logs: Bad Magic." >> $WARNFILE
   fi
}

function exists_got_signal_errors() {
   set_log_error; 
   if [ ! $LOG_ERROR ]; then return; fi
   if [ ! -f $LOG_ERROR ]; then return; fi
   GOTSIGNAL=$(tail -100000 $LOG_ERROR | grep 'got signal'|wc -l)
   if [ ! $GOTSIGNAL == "0" ]; then
     echo "This MariaDB instance has crashed recently." >> $WARNFILE
   fi
}

function exists_replica_not_started() {
  if [ ! $CAN_CONNECT ]; then return; fi
  SLAVE_STATUS=$(mariadb -Ae "show all slaves status\G"| grep Slave_SQL_Running_State | head -1 | xargs)
  if [ "$SLAVE_STATUS" == "Slave_SQL_Running_State:" ]; then echo "Replication is not running." >> $WARNFILE; fi
}

function exists_does_not_exist_in_columnstore() {
   IDB2006=$(find /var/log/mariadb/columnstore/ -name "warning.log*" ! -name "*gz" | xargs grep 'IDB-2006' | wc -l)
   if [ ! "$IDB2006" == "0" ]; then
     echo "Errors found in warning logs: IDB-2006 does not exist in Columnstore. MariaDB may be out of sync with Columnstore or there may be a problem with the extent map." >> $WARNFILE
   fi
}

function exists_holding_table_lock() {
   IDB2009=$(find /var/log/mariadb/columnstore/ -name "err.log*" ! -name "*gz" | xargs grep 'IDB-2009' | wc -l)
   if [ ! "$IDB2009" == "0" ]; then
     echo "Errors found in err logs: IDB-2009 Unable to perform the update operation because DMLProc is currently holding the table lock." >> $WARNFILE
   fi
}

function exists_data1_dir_wrong_access_rights() {
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  if [ -L $DATA1DIR ]; then return; fi # if a symbolic link, then ignore this
  DATA1DIR_ACCESS_RIGHTS=$(stat -c "%a" $DATA1DIR)
  if [ ! "$DATA1DIR_ACCESS_RIGHTS" == "1755" ]; then
    echo "The octal for directory $DATA1DIR should be 1755 and it is not." >> $WARNFILE
  fi
}

function exists_systemFiles_dir_wrong_access_rights() {
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  SYSTEMFILES=$DATA1DIR/systemFiles
  SYSTEMFILES_ACCESS_RIGHTS=$(stat -c "%a" $SYSTEMFILES)
  if [ ! "$SYSTEMFILES_ACCESS_RIGHTS" == "1755" ]; then
    echo "The octal for directory $SYSTEMFILES should be 1755 and it is not." >> $WARNFILE
  fi 
}

function exists_any_idb_errors() {
   ANY_IDB=$(grep -oh "IDB-[0-9][0-9][0-9][0-9]" /var/log/mariadb/columnstore/*.log | sort | uniq |sed -z 's/\n/, /g;s/,$/\n/' | sed 's/, *$//g')
   if [ "$ANY_IDB" ]; then
     echo "The following IDB errors exist in the logs: $ANY_IDB." >> $WARNFILE
   fi
}

function exists_cpu_unsupported_2208() {
  if [ -z $(cat /proc/cpuinfo | grep -E 'sse4_2|neon|asimd' | head -c1) ]; then
    echo "The machine CPU lacks of support for Intel SSE4.2 or ARM Advanced SIMD, required for Columnstore 22.08+." >> $WARNFILE
  fi
}

function exists_symbolic_links_in_columnstore_dir() {
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  COLUMNSTOREDIR=$(dirname $DATA1DIR)
  SYMLINKS=$(find $COLUMNSTOREDIR -maxdepth 2 -type l | wc -l)
  if [ ! "$SYMLINKS" == "0" ]; then
      if [ $SYMLINKS == "1" ]; then
        echo "There is 1 symbolic link found in $COLUMNSTOREDIR." >> $WARNFILE
      else
        SYMLINKS=$(printf "%'d" $SYMLINKS)
        echo "There are $SYMLINKS symbolic links found in $COLUMNSTOREDIR." >> $WARNFILE
      fi
  fi
}

function get_out_of_sync_tables() {
SQL="SELECT
A.TABLE_SCHEMA AS 'SCHEMA NAME', A.TABLE_NAME AS 'TABLE NAME',
if(C.ENGINE IS NULL,'No','Yes') AS 'TABLE EXISTS, NOT COLUMNSTORE ENGINE'
FROM information_schema.COLUMNSTORE_TABLES A
left join information_schema.TABLES C
ON A.TABLE_SCHEMA=C.TABLE_SCHEMA AND A.TABLE_NAME=C.TABLE_NAME
WHERE NOT EXISTS
(SELECT 'x' FROM information_schema.TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
AND B.ENGINE='Columnstore')
ORDER BY A.TABLE_SCHEMA, A.TABLE_NAME;"

  OUT_OF_SYNC_TABLES="$(timeout 3 mariadb -v -v -v -Ae "$SQL" | sed -nr '/^(\+|^\|)/p')"
}

function get_out_of_sync_tables_count() {
SQL="SELECT COUNT(*)
FROM information_schema.COLUMNSTORE_TABLES A
WHERE NOT EXISTS
(SELECT 'x' FROM information_schema.TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
AND B.ENGINE='Columnstore');"

  COLUMNSTORE_TABLES_NOT_IN_MARIABD=$(timeout 3 mariadb -ABNe "$SQL")

}

function exists_schema_out_of_sync() {
if [ ! $CAN_CONNECT ]; then return; fi
if [ ! $CS_RUNNING ]; then return; fi
get_out_of_sync_tables_count
if [ ! $COLUMNSTORE_TABLES_NOT_IN_MARIABD ]; then return; fi
if [ ! "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ]; then
get_out_of_sync_tables
  echo >> $WARNFILE
  echo "The following tables exist as Columnstore extents but not in Mariadb as Columnstore tables." >> $WARNFILE
  echo  "$OUT_OF_SYNC_TABLES" >> $WARNFILE
  echo "Run columnstore_review.sh --schemasync for options to fix out-of-sync tables." >> $WARNFILE
  echo >> $WARNFILE
fi
}

function get_no_extents_count() {
SQL="SELECT COUNT(*)
FROM information_schema.TABLES A
WHERE A.ENGINE='Columnstore'
AND A.TABLE_SCHEMA<>'calpontsys'
AND NOT EXISTS
(SELECT 'x' FROM information_schema.COLUMNSTORE_TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME)
ORDER BY A.TABLE_SCHEMA, A.TABLE_NAME;"

  NO_EXTENTS_COUNT=$(timeout 3 mariadb -ABNe "$SQL")

}

function get_columnstore_tables_with_no_columnstore_extents() {
SQL="SELECT
A.TABLE_SCHEMA AS 'SCHEMA NAME', A.TABLE_NAME AS 'TABLE NAME'
FROM information_schema.TABLES A
WHERE A.ENGINE='Columnstore'
AND A.TABLE_SCHEMA<>'calpontsys'
AND NOT EXISTS
(SELECT 'x' FROM information_schema.COLUMNSTORE_TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME)
ORDER BY A.TABLE_SCHEMA, A.TABLE_NAME;"

  NO_CS_EXTENTS="$(timeout 3 mariadb -v -v -v -Ae "$SQL" | sed -nr '/^(\+|^\|)/p')"
}

exists_columnstore_tables_with_no_extents() {
if [ ! $CAN_CONNECT ]; then return; fi
if [ ! $CS_RUNNING ]; then return; fi
get_no_extents_count
if [ ! $NO_EXTENTS_COUNT ]; then return; fi
if [ ! "$NO_EXTENTS_COUNT" == "0" ]; then
get_columnstore_tables_with_no_columnstore_extents
  echo >> $WARNFILE
  echo "The following tables exist in MariaDB as Columnstore tables but do have have columnstore extents." >> $WARNFILE
  echo  "$NO_CS_EXTENTS" >> $WARNFILE
  echo >> $WARNFILE
fi
}

function report_top_for_mysql_user() {
  if [ ! $MARIADB_RUNNING ] && [ ! $CS_RUNNING ]; then return; fi
  print_color "### Top for mysql user processes ###\n"
  TOP="$(top -bc -n1 -u mysql)"
  if [ ! -z "$TOP" ]; then ech0 "$TOP"; else print0 "No results from top to show.\n"; fi
  ech0
}

function report_last_10_error_log_error() {
  if [ ! $LOG_ERROR ]; then return; fi
  print_color "### Last 10 Errors in MariaDB Server Log ###\n"
  LAST_10=$(tail -5000 $LOG_ERROR | grep -i error | tail -10)
  if [ ! -z "$LAST_10" ]; then print0 "$LAST_10\n"; else print0 "No recent errors found in MariaDB Server error log.\n"; fi
  ech0
}

function report_last_5_columnstore_err_log() {
  CS_ERR_LOG=/var/log/mariadb/columnstore/err.log
  if [ ! -f $CS_ERR_LOG ]; then return; fi
  print_color "### Last 5 Lines of Columnstore Error Log ###\n"
  LAST_5=$(tail -5 $CS_ERR_LOG | awk '{$1=$1};1')
  if [ ! -z "$LAST_5" ]; then print0 "$LAST_5\n"; else print0 "Nothing found in Columnstore Error Log.\n"; fi
  ech0
} 

function report_cs_table_locks() {
  if [ ! $CS_RUNNING ]; then return; fi
  print_color "### Columnstore Table Locks ###\n"
  TABLE_LOCKS=$(timeout 5 viewtablelock 2>/dev/null)
  if [ ! -z "$TABLE_LOCKS" ]; then print0 "$TABLE_LOCKS\n"; else print0 "The command viewtablelock timed out or an error occurred.\n"; fi
  ech0
}

function report_machine_architecture() {
   print_color "### Machine Architecture ###\n"
   if [ "$(grep docker /proc/1/cgroup 2>/dev/null)" ]; then
     ARCH="Docker Container"
   else
     ARCH=$(hostnamectl | grep -E "(Static|Chassis|Virtualization|Operat|Kernel|Arch)" 2>/dev/null)
   fi
   if [ ! -z "$ARCH" ]; then print0 "$ARCH\n"; else print0 "Architecture not available.\n"; fi
   ech0
}

function report_cpu_info() {
   print_color "### CPU Information ###\n"
   CPUINFO=$(lscpu | grep -E "(op-mode|ddress|hread|ocket|name|MHz|vendor|cache)" 2>/dev/null)
   if [ ! -z "$CPUINFO" ]; then print0 "$CPUINFO\n"; else print0 "CPU info is not available.\n"; fi
   ech0
}

function report_disk_space() {
   print_color "### Storage (excluding tmpfs) ###\n"
   DFH=$(df -h | grep -v "tmpfs")
   if [ ! -z "$DFH" ]; then ech0 "$DFH"; else print0 "Free space info is not available.\n"; fi
   ech0
}

function report_memory_info() {
   print_color "### Memory Information ###\n"
   MEMINFO=$(free -h 2>/dev/null)
   if [ ! -z "$MEMINFO" ]; then print0 "$MEMINFO\n"; else print0 "Memory info is not available.\n"; fi
   ech0
}

function report_columnstore_mounts() {
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  CSDIR=$(basename $(dirname $DATA1DIR))
  print_color "### Columnstore Mounts ###\n"
  COLSTORE_MOUNTS=$(mount | grep $CSDIR)
  if [ ! -z "$COLSTORE_MOUNTS" ]; then print0 "$COLSTORE_MOUNTS\n"; 
  else 
  for ((i=1;i<=9;i++)); do
  DDIR=$(mcsGetConfig SystemConfig DBRoot${i} 2>/dev/null)
    if [ ! -z $DDIR ]; then
      if [ -L $DDIR ]; then
         if [ $SYMLINKSINPLACE ]; then ech0 '--'; fi
         RDLINK=$(readlink $DDIR)
         ech0 "$DDIR is a symbolic link to $RDLINK"
         COLSTORE_MOUNTS=$(mount | grep $RDLINK)
         if [ ! -z "$COLSTORE_MOUNTS" ]; then print0 "$COLSTORE_MOUNTS\n"; fi
         SYMLINKSINPLACE=true
      fi
    fi
  done
  if [ ! $SYMLINKSINPLACE ]; then print0 "No file system mount with directory name like $CSDIR.\n"; fi
  fi
  ech0
}

function report_storage_type() {
  if [ ! $CS_INSTALLED ]; then return; fi
  print_color "### Storage Type ###\n"
  STORAGE_TYPE=$(grep service /etc/columnstore/storagemanager.cnf | grep -v "^\#" | grep "\=" | awk -F= '{print $2}' | xargs)
  if [ ! -z "$STORAGE_TYPE" ]; then print0 "$STORAGE_TYPE\n"; else print0 "Storage type not found.\n"; fi
  ech0
}

function report_listening_procs() {
  print_color "### Listening Processes ###\n"
  LISTENING=$(lsof -i | grep LISTEN | grep -E "(mariadb|workernod|controlle|PrimProc|ExeMgr|WriteEngi|DMLProc|DDLProc|python3)")
  if [ ! -z "$LISTENING" ]; then print0 "$LISTENING\n"; else print0 "No mariadb processes listening.\n"; fi
  ech0
}

function report_columnstore_query_count() {
if [ $CS_RUNNING ] && [ $CAN_CONNECT ]; then
  print_color "### Columnstore Queries ###\n"
  ech0 "$(timeout 3 mariadb -ABNe 'select calgetsqlcount();')"
  ech0
fi
}

function report_host_datetime() {
  print_color "### Host DateTime ###\n"
  DT=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null);
  if [ ! -z "$DT" ]; then print0 "$DT\n"; else print0 "The command date failed.\n"; fi
  ech0
}

function report_local_hostname_and_ips() {
  print_color "### Hostname / IPs ###\n"
  ech0 "$(hostname -f 2>/dev/null) / $(hostname -I 2>/dev/null)" || ech0 "The command hostname failed.\n"
  ech0
}

function report_db_processes(){
  if [ ! $CAN_CONNECT ]; then return; fi
  print_color "### MariaDB Database Connections ###\n"
  PROCS=$(mariadb -v -v -v -Ae "select count(*) as 'HOW_MANY', user as 'USER' from information_schema.processlist where user<>'system user' AND host<>'localhost' group by user;" | sed -nr '/^(\+|^\|)/p')
  if [ ! -z "$PROCS" ]; then print0 "$PROCS\n"; else print0 "No connections.\n"; fi
  ech0
}

function report_slave_status(){
  if [ ! $CAN_CONNECT ]; then return; fi
  print_color "### Slave Status ###\n"
  SLAVE_STATUS=$(mariadb -Ae "show all slaves status\G"| grep Slave_SQL_Running_State | head -1 | xargs)
  if [ "$SLAVE_STATUS" == "Slave_SQL_Running_State:" ]; then print0 "Replication is not running.\n"; ech0; return; fi
  if [ ! -z "$SLAVE_STATUS" ]; then print0 "$SLAVE_STATUS\n"; else print0 "Not a slave.\n"; fi
  ech0
}

function report_slave_hosts() {
   if [ ! $CAN_CONNECT ]; then return; fi
   print_color "### Replicas ###\n"
   REPLICAS=$(mariadb -v -v -v -Ae "show slave hosts;" | sed -nr '/^(\+|^\|)/p')
   if [ ! -z "$REPLICAS" ]; then print0 "$REPLICAS\n"; else print0 "No replicas found.\n"; fi
   ech0
}

function report_columnstore_tables() {
   if [ ! $CAN_CONNECT ]; then return; fi
   print_color "### Columnstore Tables ###\n"
   TABLESUMMARY=$(mariadb -v -v -v -Ae "select TABLE_SCHEMA as 'SCHEMA', count(*) as 'COLUMNSTORE_TABLES' from information_schema.tables where ENGINE='Columnstore' group by table_schema order by table_schema;" | sed -nr '/^(\+|^\|)/p')
   TABLECOUNT=$(mariadb -v -v -v -Ae "select count(*) as 'TABLE COUNT', engine as 'ENGINE' from information_schema.tables where table_schema not in ('sys','information_schema','mysql','performance_schema') group by engine;" | sed -nr '/^(\+|^\|)/p') 
   if [ ! -z "$TABLESUMMARY" ]; then print0 "$TABLESUMMARY\n"; fi
   if [ ! -z "$TABLECOUNT" ]; then print0 "$TABLECOUNT\n"; fi
   ech0
}

function report_topology() {
  if [ ! $CS_INSTALLED ]; then return; fi
  PM1=$(mcsGetConfig pm1_WriteEngineServer IPAddr)
  PM2=$(mcsGetConfig pm2_WriteEngineServer IPAddr)
  print_color "### Columnstore Topology ###\n"
  if [ ! "$PM1" == "127.0.0.1" ] && [ ! -z $PM2 ]; then
    THISISCLUSTER=true
    print0 "Cluster\n"
    THISHOSTIPS="$(hostname -i)"
    for ((i=1;i<=9;i++)); do
      IPADDRESS=$(mcsGetConfig pms${i} ipaddr)
      if [ $IPADDRESS ]; then
        unset THISHOST
        if [[ "$THISHOSTIPS" == *"$IPADDRESS"* ]]; then THISHOST="(This host)"; fi
        ech0 "pm$i $IPADDRESS $THISHOST"
      fi
    done
  else
    print0 "Not a cluster\n"
  fi
  unset PM1 PM2
  ech0
}

function report_dbroots() {
  if [ ! $CS_INSTALLED ]; then return; fi
  print_color "### DBRoots ###\n"
  DBROOTS=$(mcsGetConfig -a | grep ModuleDBRootID | grep -v unassigned || ech0 'Something went wrong querying DBRoots.')
  print0 "$DBROOTS\n"
  ech0
}

function report_brm_saves_current() {
  if [ ! $CS_INSTALLED ]; then return; fi
  STORAGE_TYPE=$(grep service /etc/columnstore/storagemanager.cnf | grep -v "^\#" | grep "\=" | awk -F= '{print $2}' | xargs | awk '{print tolower($0)}')
  if [ ! "$STORAGE_TYPE" == "localstorage" ]; then return; fi
  print_color "### Current BRM Files ###\n"
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  BRMSAV=$(cat $DATA1DIR/systemFiles/dbrm/BRM_saves_current || ech0 'BRM_saves_current does not exist.')
  print0 "$BRMSAV\n"
  ech0
}

function report_calpontsys_exists() {
  if [ ! $CAN_CONNECT ]; then return; fi
  print_color "### Calpontsys Schema ###\n"
  IS_CALPONTSYS=$(mariadb -ABNe "select 'yes' from information_schema.schemata where schema_name='calpontsys' limit 1;")
  IS_CALPONTSYS_SYSTABLE=$(mariadb -ABNe "select 'yes' from information_schema.tables where table_schema='calpontsys' and table_name='systable' limit 1;")
  IS_CALPONTSYS_SYSCOLUMN=$(mariadb -ABNe "select 'yes' from information_schema.tables where table_schema='calpontsys' and table_name='syscolumn' limit 1;")
  if [ "$IS_CALPONTSYS" == "yes" ]; then print0 "The database schema calpontsys exists.\n"; else print0 "The schema calpontsys does not exist.\n"; return; fi
  if [ "$IS_CALPONTSYS_SYSTABLE" == "yes" ]; then print0 "The table calpontsys.systable exists.\n"; else print0 "The table calpontsys.systable does not exist.\n"; fi
  if [ "$IS_CALPONTSYS_SYSCOLUMN" == "yes" ]; then print0 "The table calpontsys.syscolumn exists.\n"; else print0 "The table calpontsys.syscolumn does not exist.\n"; fi
  ech0
}

function displaytime() {
  local T=$1
  local W=$((T/60/60/24/7))
  local D=$((T/60/60/24%7))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  (( $W > 1 )) && printf '%d weeks, ' $W
  (( $W == 1 )) && printf '%d week, ' $W
  (( $D > 1 )) && printf '%d days, ' $D
  (( $D == 1 )) && printf '%d day, ' $D
  (( $H > 1 )) && printf '%d hours, ' $H
  (( $H == 1 )) && printf '%d hour, ' $H
  (( $M > 1 )) && printf '%d minutes ' $M 
  (( $M == 1 )) && printf '%d minute ' $M
  (( $M == 0 )) && printf '0 minutes ' $M
}

function report_uptime() {
  print_color "### UPTIME ###\n"
  ech0 "Host uptime:               $(uptime -p)"
  if [ ! $CAN_CONNECT ]; then ech0; return; fi
  SCNDS=$(mariadb -ABNe "show global status like 'Uptime';" | awk '{print $2}')
  ech0 "Mariadb uptime:            up $(displaytime $SCNDS)"
  CMAPIPID=$(pidof /usr/share/columnstore/cmapi/python/bin/python3)
  if [ "$CMAPIPID" ]; then
    CMAPI_UPTIME=$(ps -p $CMAPIPID -o etimes | tail -1 | xargs)
    ech0 "Cmapi uptime:              up $(displaytime $CMAPI_UPTIME)"
  fi
  WORKERNODEPID=$(pidof /usr/bin/workernode)
  if [ "$WORKERNODEPID" ]; then
     WORKERNODE_UPTIME=$(ps -p $WORKERNODEPID -o etimes | tail -1 | xargs)
     echo "Workernode uptime:         up $(displaytime $WORKERNODE_UPTIME)"
  fi  
  CONTROLLERNODEPID=$(pidof /usr/bin/controllernode)
  if [ "$CONTROLLERNODEPID" ]; then
     CONTROLLERNODE_UPTIME=$(ps -p $CONTROLLERNODEPID -o etimes | tail -1 | xargs)
     echo "Controlernode uptime:      up $(displaytime $CONTROLLERNODE_UPTIME)"
  fi
  PRIMPROCPID=$(pidof /usr/bin/PrimProc)
  if [ "$PRIMPROCPID" ]; then
     PRIMPROC_UPTIME=$(ps -p $PRIMPROCPID -o etimes | tail -1 | xargs)
     echo "Primproc uptime:           up $(displaytime $PRIMPROC_UPTIME)"
  fi  
  EXEMGRPID=$(pidof /usr/bin/ExeMgr)
  if [ "$EXEMGRPID" ]; then
     EXEMGR_UPTIME=$(ps -p $EXEMGRPID -o etimes | tail -1 | xargs)
     echo "ExeMgr uptime:             up $(displaytime $EXEMGR_UPTIME)"
  fi  
  WRITEENGINESERVERPID=$(pidof /usr/bin/WriteEngineServer)
  if [ "$WRITEENGINESERVERPID" ]; then
     WRITEENGINESERVER_UPTIME=$(ps -p $WRITEENGINESERVERPID -o etimes | tail -1 | xargs)
     echo "WriteEngineServer uptime:  up $(displaytime $WRITEENGINESERVER_UPTIME)"
  fi
  DMLPROCPID=$(pidof /usr/bin/DMLProc)
  if [ "$DMLPROCPID" ]; then
     DMLPROC_UPTIME=$(ps -p $DMLPROCPID -o etimes | tail -1 | xargs)
     echo "DMLProc uptime:            up $(displaytime $DMLPROC_UPTIME)"
  fi  
  DDLPROCPID=$(pidof /usr/bin/DDLProc)
  if [ "$DDLPROCPID" ]; then
     DDLPROC_UPTIME=$(ps -p $DDLPROCPID -o etimes | tail -1 | xargs)
     echo "DDLProc uptime:            up $(displaytime $DDLPROC_UPTIME)"
  fi 
  ech0
}

function report_versions() {
   if [  $CAN_CONNECT ]; then
     print_color "### MariaDB Version ###\n"
     ech0 "$(mariadb -ABNe "select version();")"
     ech0
     if [ $CS_INSTALLED ]; then
       print_color "### Columnstore Version ###\n"
       ech0 "$(mariadb -ABNe "show global status like 'Columnstore_version';")"
       ech0
     fi
   else
        print_color "### MariaDB Version ###\n"
        MDBVS="$(find /usr -name mariadbd -exec {} --version \; 2>/dev/null || echo 'MariaDB Version not available.')"
        print0 "$MDBVS\n"
        ech0
     if [ -f /usr/share/columnstore/releasenum ]; then
        print_color "### Columnstore Version ###\n"
        CSVS="$(cat /usr/share/columnstore/releasenum 2>/dev/null || echo 'Columnstore Version not available.')"
        print0 "$CSVS\n"
        ech0
     fi
   fi
   CMAPI_VERSION_FILE=/usr/share/columnstore/cmapi/VERSION
   if [ -f $CMAPI_VERSION_FILE ]; then
     . $CMAPI_VERSION_FILE
     if [ $CMAPI_VERSION_MAJOR ]; then
       print_color "### CMAPI Version ###\n"
       ech0 $CMAPI_VERSION_MAJOR.$CMAPI_VERSION_MINOR.$CMAPI_VERSION_PATCH
       ech0
     fi
   fi
}

function report_warnings() {
  print_color "### Warnings ###\n"
  WARNINGS=$(cat $WARNFILE)
  if [ ! -z "$WARNINGS" ]; then print0 "$WARNINGS\n"; else print0 "There are no warnings to report.\n"; fi
  ech0
}

function report_datadir_size() {
  set_log_error
  if [ ! $DATADIR ]; then return; fi
  if [ -d $DATADIR ]; then
    print_color "### Mariadb Datadir Size ###\n"
    ech0 "$(du -sh $DATADIR)"
    ech0
  fi
}

function set_log_error() {
  unset DATADIR LOG_ERROR FULL_PATH
  if [ $CAN_CONNECT ]; then
    LOG_ERROR=$(mariadb -ABNe "select @@log_error")
    DATADIR=$(mariadb -ABNe "select @@datadir" | sed 's:/*$::')
  else
    LOG_ERROR=$(my_print_defaults --mysqld| grep log_error | tail -1 | cut -d "=" -f2)
    DATADIR=$(my_print_defaults --mysqld| grep datadir | tail -1 | cut -d "=" -f2 | sed 's:/*$::')
  fi
  if [ -z "$LOG_ERROR" ]; then unset LOG_ERROR; return; fi;
  if [[ $LOG_ERROR =~ ^/.* ]]; then FULL_PATH=true; fi

  if [ ! $FULL_PATH ]; then
    LOG_ERROR=$(basename $LOG_ERROR)
    LOG_ERROR=$DATADIR/$LOG_ERROR
  fi
}

function collect_logs() {
  LOGSOUTDIR=/tmp/columnstore_review/logs_$(date +"%m-%d-%H-%M-%S")/$(hostname)
  mkdir -p $LOGSOUTDIR || ech0 'Cannot create temporary directory for logs.';
  mkdir -p $LOGSOUTDIR/system
  mkdir -p $LOGSOUTDIR/mariadb
  mkdir -p $LOGSOUTDIR/columnstore
  COMPRESSFILE=$(hostname)_$(date +"%Y-%m-%d-%H-%M-%S")_logs.tar.gz
  set_log_error
  if [ $LOG_ERROR ]; then
    OUTFILE=$LOGSOUTDIR/mariadb/$(hostname)_$(date +"%Y-%m-%d-%H-%M-%S")_$(basename $LOG_ERROR)
    FILTEREDFILE=$LOGSOUTDIR/mariadb/$(hostname)_$(date +"%Y-%m-%d-%H-%M-%S")_filtered_$(basename $LOG_ERROR)
    if [ -f $LOG_ERROR ]; then
      tail -100000 $LOG_ERROR > $OUTFILE
    fi
    if [ -f $LOG_ERROR ]; then
      tail -1000000 $LOG_ERROR | grep -iv "\[warning\]"|grep -iv "\[note\]"  > $FILTEREDFILE
    fi
  fi
  cp /etc/columnstore/Columnstore.xml $LOGSOUTDIR/columnstore
  #  find /var/log \( -name "messages" -o -name "messages.1" \) -type f -exec cp {} $LOGSOUTDIR/system \;
  cp /var/log/messages* $LOGSOUTDIR/system
  find /var/log/syslog -name syslog -type f -exec tail -10000 {} > $LOGSOUTDIR/system/syslog \;
  find /var/log/daemon.log -name daemon.log -type f -exec tail -10000 {} > $LOGSOUTDIR/system/daemon.log \;
  cd /var/log/mariadb

  ls -1 columnstore/*.log 2>/dev/null | cpio -pd $LOGSOUTDIR/ 2>/dev/null
  ls -1 columnstore/*z 2>/dev/null | cpio -pd $LOGSOUTDIR/ 2>/dev/null
  find columnstore/archive columnstore/install columnstore/trace -mtime -30 | cpio -pd $LOGSOUTDIR/ 2>/dev/null 
  find columnstore/cpimport -mtime -1 | cpio -pd $LOGSOUTDIR/ 2>/dev/null

  if [ $CAN_CONNECT ]; then
    mariadb -ABNe "show global variables" > $LOGSOUTDIR/mariadb/$(hostname)_global_variables.txt 2>/dev/null
    mariadb -ABNe "show global status" > $LOGSOUTDIR/mariadb/$(hostname)_global_status.txt 2>/dev/null
  fi
  my_print_defaults --mysqld > $LOGSOUTDIR/mariadb/$(hostname)_my_print_defaults.txt 2>/dev/null 
  if [ -f $OUTPUTFILE ]; then cp $OUTPUTFILE $LOGSOUTDIR/; fi
  cd $LOGSOUTDIR/..
  tar -czf /tmp/$COMPRESSFILE ./*
  cd - 1>/dev/null 
  print_color "### COLLECTED LOGS FOR SUPPORT TICKET ###\n"
  ech0 "Attach file /tmp/$COMPRESSFILE to your support ticket."
  if [ $THISISCLUSTER ]; then
    ech0 "Please collect logs with this script from each node in your cluster."
  fi
  FILE_SIZE=$(stat -c %s /tmp/$COMPRESSFILE)
  if (( $FILE_SIZE > 52428800 )); then
    print0 "The file /tmp/$COMPRESSFILE is larger than 50MB.\nPlease use MariaDB Large file upload at https://mariadb.com/upload/\nInform us about the upload in the support ticket."
  fi 
  ech0
}

function empty_directories(){
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  COLUMNSTOREDIR=$(dirname $DATA1DIR)
  print0 "Empty directories in $COLUMNSTOREDIR can be caused by failed runs of cpimport.\nThey are not necessarily a serious issue.\n"
  ech0
  print_color "### Empty Directories in $COLUMNSTOREDIR ###\n"
  EMPTY_DIRS=$(find $COLUMNSTOREDIR -type d -name "[0-9][0-9][0-9].dir" -empty)
  ech0 "$EMPTY_DIRS"
  ech0
  display_outputfile_message
}

function not_mysql_directories(){
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  COLUMNSTOREDIR=$(dirname $DATA1DIR)
  print0 "There should not be any directores in $COLUMNSTOREDIR that are not owned by mysql.\n"
  ech0
  print_color "### Directories not owned by mysql ###\n"
  NOT_MYSQL_DIRS=$(find $COLUMNSTOREDIR/ ! -user mysql -type d)
  ech0 "$NOT_MYSQL_DIRS"
  ech0
  display_outputfile_message
}

function add_pscs_alias() {
CSALIAS=/etc/profile.d/columnstoreAlias.sh
if [ ! -f $CSALIAS ]; then
  TEMP_COLOR=lred; print_color "The file $CSALIAS is missing."; unset TEMP_COLOR; exit 0;
fi
PSCS=$(grep alias $CSALIAS | sed 's,=.*,,' | awk '{print $2}' | grep pscs | head -1)
if [ ! $PSCS ]; then
   print_color "### Adding pscs alias to $CSALIAS ###\n"
   echo "" >> $CSALIAS
   echo "# pscs by Edward Stoever for Mariadb Support" >> $CSALIAS
   printf "alias pscs=\'ps -ef | grep -E \"(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|StorageManager|controllernode|workernode)\" | grep -v \"grep\"\'\n\n" >> $CSALIAS
   ech0 "The alias pscs was added to $CSALIAS."
   ech0 "To use the command, source the file $CSALIAS or logout and login."
else
  ech0 "The alias pscs is already included in $CSALIAS."
fi
ech0
}

function create_test_schema() {
if [[ "$(ps -ef | grep -E "(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|StorageManager|controllernode|workernode)" | grep -v "grep"|wc -l)" == "0" ]]; then
  ech0 "Columnstore is not running."; ech0; return;
fi
if [ ! $CAN_CONNECT ]; then
  ech0 "Cannot connect to database."; ech0; return;
fi
print_color "### Creating a Schema and Two Tables. ###\n"
ech0
print0 "If query succeeds, Columnstore is working.\n"
ech0
unset SCHEMA FILEAUTOMOBILES DATA1 SQL OUTDIR
OUTDIR=/tmp/columnstore_review; mkdir -p $OUTDIR
FILEAUTOMOBILES=$OUTDIR/automobiles.txt
FILEACCIDENTS=$OUTDIR/accindents.txt
DATA1="'Datsun','Zcar','dz01','1972',678954321,'2015-02-12 11:33:55'
'Mazda','MX-5 Miata','mm01','1978',93421329,'2016-01-19 15:01:23'
'Lada','Riva','lr01','1981',876323,'2016-03-10 08:38:51'
'Delorian','DSV-12','dd01','1979',10621,'2016-09-01 01:05:12'\n"
DATA2="'dd01','It was a complete smashup.','2020-09-02 05:09:32',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2020-10-01 12:11:31'
'mm01','It was a headon collision.','2021-01-01 06:06:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-01-02 18:11:44'
'lr01','It was a fender bender.','2021-05-22 09:23:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-06-01 08:31:18'
'dd01','Just a scratch.','2021-06-22 02:21:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-06-25 12:12:01',
'dd01','Fire damage caused by smoking.','2021-08-19 11:10:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-08-20 14:19:01'
'lr01','Dropped off cliff. Total loss.','2021-09-02 12:19:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-09-04 18:51:13'
'dz01','Complete and total smash up.','2021-12-04 18:18:00',$((101+RANDOM%(33000-101))).$((RANDOM%99)),'2021-12-05 15:50:09'\n"
if [ -f $FILEAUTOMOBILES ]; then truncate -s0 $FILEAUTOMOBILES; fi
if [ -f $FILEACCIDENTS ]; then truncate -s0 $FILEACCIDENTS; fi
printf "$DATA1" > $FILEAUTOMOBILES
printf "$DATA2" > $FILEACCIDENTS
SCHEMA=test_$(date +"%M%S")_$(echo $RANDOM | md5sum | head -c 5)_$(echo $RANDOM)_$(echo $RANDOM | md5sum | head -c 3)
SQL="create schema if not exists $SCHEMA; use $SCHEMA;
create table automobiles (make varchar(100),
                         model varchar(100),
                         model_code varchar(100),
                         year_introduced varchar(100),
                         qty_manufactured bigint,
                         data_entered datetime)
ENGINE=Columnstore DEFAULT CHARSET=utf8mb4;
create table accidents(model_code varchar(100),
                       description mediumtext,
                       occurred datetime,
                       cost float(10,2),
                       data_entered datetime)
ENGINE=Columnstore DEFAULT CHARSET=utf8mb4;"
mariadb -Ae "$SQL" || echo 'Something went wrong.'
cpimport -s "," -E "'" $SCHEMA automobiles $FILEAUTOMOBILES
cpimport -s "," -E "'" $SCHEMA accidents $FILEACCIDENTS
SQL="use $SCHEMA; select make,model, count(a.model_code) as accidents_per_model, concat('$',format(sum(cost),2)) as cost_of_all_accidents from
accidents a inner join automobiles b on a.model_code=b.model_code
group by  make, model;"
mariadb -Ae "$SQL" || ech0 'Something went wrong when querying test tables.'
SQL="drop schema $SCHEMA;"
mariadb -Ae "$SQL" && print0 "Test Schema dropped.\n\n" || ech0 'Something went wrong when dropping schema.'
}

function backup_dbrm() {
if [[ ! "$(ps -ef | grep -E "(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|StorageManager|controllernode|workernode)" | grep -v "grep"|wc -l)" == "0" ]]; then
  CS_RUNNING=true
fi

if [ $CS_RUNNING ]; then
  TEMP_COLOR=lred; print_color "Columnstore processes are running.\n"; unset TEMP_COLOR
  ech0 "Consistency among the em files is only ensured when columnstore processes are stopped."
  ech0 "Type c to continue running the script taking a backup while columnstore is running."
  ech0 "Type any other key to exit."

  read -s -n 1 RESPONSE
  if [ ! "$RESPONSE" = "c" ]; then
    print0 "\n Exiting.\n\n";  exit 0
  fi
fi
  if [ $CS_RUNNING ]; then
    COMPRESSFILE=$(hostname)_r_$(date +"%Y-%m-%d-%H-%M-%S")_dbrm.tar.gz
  else
    COMPRESSFILE=$(hostname)_s_$(date +"%Y-%m-%d-%H-%M-%S")_dbrm.tar.gz
  fi
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  cd $DATA1DIR/systemFiles
  tar -czf /tmp/$COMPRESSFILE ./dbrm
  cd - 1>/dev/null
  print_color "### DBRM EXTENT MAP BACKUP ###\n"
  ech0 "Files in dbrm directory backed up to compressed archive /tmp/$COMPRESSFILE."
  ech0 "Files in /tmp can be deleted on reboot. It is recommended to move the archive to a safe location."
  ech0
}

function oid_missing_file() {
  MISSINGFILE=$(grep $1 $FILE_EM_FILES)
  FL=$(echo "$MISSINGFILE" | awk '{print $1}')
  OID=$(echo "$MISSINGFILE" | awk '{print $2}')
  printf "$(echo $MISSINGFILE | awk '{print $2}')," >> $MISSING_OIDS;
  ech0 "$FL   OID: $OID"
}

function extent_map_check() {
if [ $CAN_CONNECT ]; then 
  IS_SYSCOLUMN=$(mariadb -ABNe "select count(*) from information_schema.tables where table_schema='calpontsys' and table_name='syscolumn';");
else
  IS_SYSCOLUMN=0;
fi
STORAGE_TYPE=$(grep service /etc/columnstore/storagemanager.cnf | grep -v "^\#" | grep "\=" | awk -F= '{print $2}' | xargs)
if [ ! "$(echo $STORAGE_TYPE | awk '{print tolower($0)}')" == "localstorage" ]; then
  TEMP_COLOR=lred; print_color "Storage type is $STORAGE_TYPE. "; unset TEMP_COLOR; print0 "This storage type is unupported for the extent map check.\n\n"; exit 0
fi

if [ ! $CAN_CONNECT ]; then
  TEMP_COLOR=lred; print_color "You cannot connect to the database. "; unset TEMP_COLOR; 
  print0 "An extent map check can be performed without listing effected database objects.\n"
fi

print_color "### Extent Map Check ###\n"
CACHEFILE=$EMOUTDIR/cachetimestamp.txt
if [ -f $CACHEFILE ]; then
  DT=$(cat $CACHEFILE|head -1); FILE_EM=$EMOUTDIR/em_$DT.txt
  if [ -f $FILE_EM ]; then
    CACHETIMESTAMP=(cat $CACHEFILE); MOD_TIME=$(stat -c %Y $CACHEFILE); RIGHTNOW=$(date +%s); HOW_LONG=$(expr $RIGHTNOW - $MOD_TIME); NUM_MINS=$(expr $HOW_LONG / 60);
    if (( $NUM_MINS < 360 )); then # DO NOT OFFER TO USE CACHED EM OLDER THAN 6 HOURS
      ech0 "It is recommended to run this process infrequently. You have a cached extent map that you can use."
      TEMP_COLOR=lmagenta; print_color "Do you want to run this report from the cached extent map file that is from $NUM_MINS minutes ago?"; unset TEMP_COLOR;
      read -r -p " [y/N] " response
      if [[ $response == "y" || $response == "Y" || $response == "yes" || $response == "Yes" ]]; then USECACHED=true; else unset USECACHED; fi
    else
      unset USECACHED
    fi
  fi
fi

if [ ! $USECACHED ]; then
  if [[ "$(ps -ef | grep -E "(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|controllernode|workernode)" | grep -v "grep"|wc -l)" == "0" ]]; then
    TEMP_COLOR=lred; print_color "\nColumnstore must be running to perform a new extent map check.\n\n"; unset TEMP_COLOR; return
  fi
fi

if [ $USECACHED ]; then
  print0 "\nUsing cached extent map file to generate report. Please wait while report is generated.\n";
  DT=$(cat $CACHEFILE|head -1)
else
  DT=$(date +"%m_%d_%H_%M_%S")
  printf $DT > $CACHEFILE
fi

if [ ! $USECACHED ]; then
ech0
if [ $CAN_CONNECT ] && [ "$IS_SYSCOLUMN" == "1" ]; then
  COLUMNSTORE_COLCOUNT=$(mariadb -ABNe "select count(1) from calpontsys.syscolumn;"); COLUMNSTORE_COLCOUNT=$(printf "%'d" $COLUMNSTORE_COLCOUNT)
  print0 "Your instance has $COLUMNSTORE_COLCOUNT Columnstore columns. There will likely be more than 2 files on disk for each column.\n"
fi
print0 "On very large databases, this process can take a long time.\n"
print0 "It is recommended that you allow this process to complete.\n"
print0 "Killing the editem process while it is running can damage the extent map.\n"
TEMP_COLOR='lred'; print_color "Do you want to run this process?"; unset TEMP_COLOR
  read -r -p " [y/N] " response
   if [[ $response == "y" || $response == "Y" || $response == "yes" || $response == "Yes" ]]; then CONTINUE=true; else ech0 "exiting..."; exit 0; fi
   if [ $CONTINUE ]; then print0 "\nGenerating a new report. This may take a while.\n"; fi;
fi

FILEPL=$EMOUTDIR/convertem.pl
FILE_EM=$EMOUTDIR/em_$DT.txt
DT=$(date +"%m_%d_%H_%M_%S")
FILE_EM_FILES=$EMOUTDIR/em_files_$DT.txt; touch $FILE_EM_FILES; truncate -s0 $FILE_EM_FILES
FILE_ALL_FILES=$EMOUTDIR/all_files_$DT.txt; touch $FILE_ALL_FILES; truncate -s0 $FILE_ALL_FILES
MISSING_FILES=$EMOUTDIR/missing_files_$DT.txt; touch $MISSING_FILES; truncate -s0 $MISSING_FILES
MISSING_OIDS=$EMOUTDIR/oids_missing_files_$DT.txt; touch $MISSING_OIDS; truncate -s0 $MISSING_OIDS

DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
COLUMNSTOREDIR=$(dirname $DATA1DIR)
PLSCRIPT="my (\$pn) = \$ARGV[0];
@parts = split(/\|/, \$pn);
if (@parts <= 7) { exit; }
\$oid = \$parts[2];
\$seqnum = \$parts[6];
\$partnum = \$parts[5];
\$dbroot = \$parts[7];
\$z1 = \$oid >> 24;
\$dir1 = sprintf('%03d',\$z1);
\$t2 = \$oid & hex '0x00FF0000';
\$z2 = \$t2 >> 16;
\$dir2 = sprintf('%03d',\$z2);
\$t3 = \$oid & hex '0x0000FF00';
\$z3 = \$t3 >> 8;
\$dir3 = sprintf('%03d',\$z3);
\$z4 = \$oid & hex '0x000000ff';
\$dir4 = sprintf('%03d',\$z4);
\$dir5 = sprintf('%03d',\$partnum);
\$dir6 = sprintf('%03d',\$seqnum);
\$fl = '$COLUMNSTOREDIR/data'.\$dbroot.'/'.\$dir1.'.dir/'.\$dir2.'.dir/'.\$dir3.'.dir/'.\$dir4.'.dir/'.\$dir5.'.dir/FILE'.\$dir6.'.cdf';
print \$fl,' ',\$oid,\"\n\";"

if [ ! $USECACHED ]; then
  printf '%s\n' "$PLSCRIPT" > $FILEPL
  editem -i > $FILE_EM 2>/dev/null || echo 'An error has occurred running editem.';
fi

  APPROX_FILE_SIZE=$(wc -c < $FILE_EM)
  if [ "$APPROX_FILE_SIZE" -lt "1000" ]; then
    if [ ! $USECACHED ]; then 
      TEMP_COLOR=lred; print_color "The output for editem is too small. "; unset TEMP_COLOR;
      print0 "Something went wrong. Check that columnstore processes are running properly.\n"; 
    else
      TEMP_COLOR=lred; print_color "The cached extent map is too small. "; unset TEMP_COLOR;
      print0 "Do not use the cached extent map file. Check that columnstore processes are running properly.\n"
    fi
    exit 0;
  fi

  cat $FILE_EM | while read line
  do
     perl $FILEPL $line >> $FILE_EM_FILES
  done
  
  APPROX_FILE_SIZE=$(wc -c < $FILE_EM_FILES)
  if [ "$APPROX_FILE_SIZE" -lt "1000" ]; then
    TEMP_COLOR=lred; print_color "The output for extent map files is too small. "; unset TEMP_COLOR; print0 "Something went wrong. Exiting\n\n"; exit 0;
  fi
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  COLUMNSTOREDIR=$(dirname $DATA1DIR)
  find -L $COLUMNSTOREDIR -iname "FILE[0-9][0-9][0-9].cdf" -type f >> $FILE_ALL_FILES

  APPROX_FILE_SIZE=$(wc -c < $FILE_ALL_FILES)
  if [ "$APPROX_FILE_SIZE" -lt "1000" ]; then
    TEMP_COLOR=lred; print_color "The output for all files is too small. "; unset TEMP_COLOR; print0 "Something went wrong. Exiting\n\n"; exit 0;
  fi

ORPHAN_COUNT=$(grep -F -x -v -f  <(cat $FILE_EM_FILES | awk '{print $1}') $FILE_ALL_FILES |wc -l)
if [ $ORPHAN_COUNT == "1" ]; then
  ORPHANED_MSG='There is 1 orphaned file:'; else ORPHANED_MSG="There are $ORPHAN_COUNT orphaned files:"
fi

MISSING_COUNT=$(grep -F -x -v -f  $FILE_ALL_FILES <(cat $FILE_EM_FILES | awk '{print $1}')|wc -l)
if [ $MISSING_COUNT == "1" ]; then
  MISSING_MSG='There is 1 missing file:'; else MISSING_MSG="There are $MISSING_COUNT missing files:"
fi

  print_color "\n### Summary ###\n"
  EM_COUNT=$(cat $FILE_EM_FILES | sort | uniq | wc -l) # Careful here, some single files have more than one entry
  ALL_FILE_COUNT=$(wc -l < $FILE_ALL_FILES);
  EM_COUNT=$(printf "%'d" $EM_COUNT); ALL_FILE_COUNT=$(printf "%'d" $ALL_FILE_COUNT);
  print0 "There are $EM_COUNT files registered in the extent map. There are $ALL_FILE_COUNT eligible columnstore extent files.\n"
  ech0

print_color "### Orphaned Files ###\n"
if [ "$ORPHAN_COUNT" -gt "0" ]; then
  ech0 "Orphaned files are those that exist on the file system but do not exist in the Columnstore extent map."
   TEMP_COLOR=lred; print_color "Mariadb Support does not recommend that orphaned files be deleted.\n"; unset TEMP_COLOR
  ech0
  if [ $USECACHED ]; then
    print0 "When a cached extent map is compared to the current file system it is possible that this script\nreports orphaned files that are not actually orphaned. This is due to tables and columns added\nsince the cached extent map was created.\n"
  fi
  ech0 "$ORPHANED_MSG"
  ech0 "$(grep -F -x -v -f  <(cat $FILE_EM_FILES | awk '{print $1}') $FILE_ALL_FILES)"
  ech0
else
  ech0 "There are no orphaned files."
  ech0
fi

print_color "### Missing files ###\n"
if [ "$MISSING_COUNT" -gt "0" ]; then
  ech0 "Missing files are those expected by the extent map but are not found on disk."
  ech0
  if [ $USECACHED ]; then
    print0 "When a cached extent map is compared to the current file system it is possible that this script\nreports missing files that are not actually missing. This is due to tables being dropped\nsince the cached extent map was created.\n"
  fi
  ech0 "$MISSING_MSG"

  grep -F -x -v -f  $FILE_ALL_FILES <(cat $FILE_EM_FILES | awk '{print $1}') > $MISSING_FILES

  cat $MISSING_FILES | while read line
  do
    oid_missing_file $line
  done
  OIDLIST=$(cat $MISSING_OIDS | sed 's/,*$//g')
  ech0
# assume errors on the next query:
  SQL="select \`schema\`,tablename,columnname, objectid, dictobjectid, listobjectid, treeobjectid
       from calpontsys.syscolumn
       where objectid in ($OIDLIST) or dictobjectid in ($OIDLIST) or listobjectid in ($OIDLIST) or treeobjectid in ($OIDLIST);"
  if [ $CAN_CONNECT ] && [ "$IS_SYSCOLUMN" == "1" ]; then
    MISSINGOIDSREPORT=$(mariadb -v -v -v -Ae "$SQL" | sed -nr '/^(\+|^\|)/p') 2>/dev/null || ERR=true
    if [ ! $ERR ]; then
      print_color "### Database Objects Effected by Missing Files ###\n"
      print0 "$MISSINGOIDSREPORT\n"
    fi
  fi
  ech0
else
  ech0 "There are no missing files."
  ech0
fi
display_outputfile_message
}

function schema_sync() {
ls /usr/bin/mariadb-columnstore-start.sh 1>/dev/null 2>/dev/null && CS_INSTALLED=true
if [ ! $CS_INSTALLED ]; then return; fi
if [ ! $CAN_CONNECT ]; then return; fi
if [[ ! "$(ps -ef | grep -E "(PrimProc|ExeMgr|DMLProc|DDLProc|WriteEngineServer|StorageManager|controllernode|workernode)" | grep -v "grep"|wc -l)" == "0" ]]; then
  CS_RUNNING=true
fi
if [ ! $CS_RUNNING ]; then ech0 "Columnstore is not running."; return; fi

PM1=$(mcsGetConfig pm1_WriteEngineServer IPAddr)
PM2=$(mcsGetConfig pm2_WriteEngineServer IPAddr)

if [ ! "$PM1" == "127.0.0.1" ] && [ ! -z $PM2 ]; then
  THISISCLUSTER=true
fi
if [ $CAN_CONNECT ]; then
get_out_of_sync_tables_count
fi

if [ ! $COLUMNSTORE_TABLES_NOT_IN_MARIABD ]; then return; fi
if [ ! "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ]; then
  get_out_of_sync_tables
  ech0 "The following tables exist as Columnstore extents but not in Mariadb as Columnstore tables."
  ech0  "$OUT_OF_SYNC_TABLES" 
fi

SLAVE_STATUS=$(mariadb -Ae "show all slaves status\G"| grep Slave_SQL_Running_State | head -1 | xargs)
if [ "$SLAVE_STATUS" == "Slave_SQL_Running_State:" ] && [ ! "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ]; then
  TEMP_COLOR=lcyan; print_color "Replication is not running. The best solution for this node may be to repair replication.\n\n";unset TEMP_COLOR;
fi

IS_THIS_A_SLAVE=$(mariadb -Ae "show all slaves status\G"| grep Slave_SQL_Running_State | head -1 |awk '{print $1}')
if [ "$IS_THIS_A_SLAVE" == "Slave_SQL_Running_State:" ]; then IS_THIS_A_SLAVE=true; else unset IS_THIS_A_SLAVE; fi

NO_APPROPRIATE_OPTIONS=true

print0 "Use this routine to dynamically generate a script. There are three methods to choose from:\n"
ech0 "----------------"
if [ ! $THISISCLUSTER ]; then
  TEMP_COLOR=lred; print_color "Option 1 is useful for Columnstore clusters only.\n"; unset TEMP_COLOR
else
  print0 "Respond with "; TEMP_COLOR=lcyan; print_color "1"; unset TEMP_COLOR
  print0 " to create a SQL script from mariadb-dump (mysqldump).\n"

  print0 "Use option 1 on a node with all the tables defined correctly that primary/master.\nThis option is to be used when a replica is missing table definitions because replication broke.\nTransfer the resulting script to the replica and run it there.\n"
  if [ ! "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ] || [ $IS_THIS_A_SLAVE ]; then
    TEMP_COLOR=lred; print_color "Option 1 is not appropriate on this node. "; unset TEMPCOLOR
    if [ $IS_THIS_A_SLAVE ]; then TEMP_COLOR=lmagenta; print_color "This is a replica.\n"  unset TEMP_COLOR; else print0 "\n"; fi
  else 
    TEMP_COLOR=lgreen; print_color "Option 1 is appropriate on this node.\n"; unset TEMP_COLOR NO_APPROPRIATE_OPTIONS; ENABLE_OP1=true
  fi
fi
ech0 "----------------"
print0 "Respond with "; TEMP_COLOR=lcyan; print_color "2"; unset TEMP_COLOR;
print0 " to generate a SQL script that will redefine out-of-sync columnstore tables in MariaDB.\n"
if [ "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ]; then
  TEMP_COLOR=lred; print_color "Option 2 is not appropriate on this node.\n"; unset TEMP_COLOR
else
  TEMP_COLOR=lgreen; print_color "Option 2 is appropriate on this node.\n"; unset TEMP_COLOR NO_APPROPRIATE_OPTIONS; ENABLE_OP2=true
fi

ech0 "----------------"
print0 "Respond with "; TEMP_COLOR=lcyan; print_color "3"; unset TEMP_COLOR;
print0 " to generate a SQL script that can be used to permanently delete out-of-sync columnstore extents.\n"
if [ "$COLUMNSTORE_TABLES_NOT_IN_MARIABD" == "0" ]; then
  TEMP_COLOR=lred; print_color "Option 3 is not appropriate on this node.\n"; unset TEMP_COLOR
else
  TEMP_COLOR=lgreen; print_color "Option 3 is appropriate on this node.\n"; unset TEMP_COLOR NO_APPROPRIATE_OPTIONS; ENABLE_OP3=true
fi
ech0 "----------------"

if [ $NO_APPROPRIATE_OPTIONS ]; then print0 "No appropriate options for this node. Exiting.\n\n"; exit 0; fi

TEMP_COLOR=lgreen; print_color "Choose one of these options:\n"; unset TEMP_COLOR
if [ $ENABLE_OP1 ]; then
  TEMP_COLOR=lcyan; print_color "  1"; unset TEMP_COLOR; ech0 ") Generate SQL script from mariadb-dump to resync columnstore tables on another node."
fi
if [ $ENABLE_OP2 ]; then
  TEMP_COLOR=lcyan; print_color "  2"; unset TEMP_COLOR; ech0 ") Generate SQL script that can be used to re-sync columnstore tables."
fi
if [ $ENABLE_OP3 ]; then
  TEMP_COLOR=lcyan; print_color "  3"; unset TEMP_COLOR; ech0 ") Generate SQL script that can be used to permanently delete out-of-sync columnstore extents."
fi
TEMP_COLOR=lcyan; print_color "  4"; unset TEMP_COLOR; ech0 ") Do nothing, exit." 

read yourchoice
case $yourchoice in
  1) ech0 "Option 1 chosen"; if [ ! $ENABLE_OP1 ]; then ech0 "Exiting."; exit 0; fi; mariadb_dump_to_resync_columnstore_tables;;
  2) ech0 "Option 2 chosen"; if [ ! $ENABLE_OP2 ]; then ech0 "Exiting."; exit 0; fi; generate_sql_to_resync_columnstore_tables;;
  3) ech0 "Option 3 chosen"; if [ ! $ENABLE_OP3 ]; then ech0 "Exiting."; exit 0; fi; generate_sql_to_delete_out_of_sync_columnstore_extents;;
  *) exit 0;;
esac

}

function mariadb_dump_to_resync_columnstore_tables() {
  SQLFILE=/tmp/rebuild_schema_sync_only.sql
  TEMPSCRIPT=/tmp/mariadb-dump_table_definitons.sh

  printf "/* Dynamically generated SQL to restore lost columnstore tables on cluster replica. */\n/* Script by Edward Stoever for MariaDB Support */\n" > $SQLFILE
  printf "#!/bin/bash\n# Script by Edward Stoever for MariaDB Support.\n" > $TEMPSCRIPT
  mariadb -ABNe "select distinct concat('echo \"SET sql_log_bin = OFF;\" >> $SQLFILE; ')as txt" >> $TEMPSCRIPT
  mariadb -ABNe "select distinct concat('echo \"CREATE SCHEMA IF NOT EXISTS ',TABLE_SCHEMA,';\" >> $SQLFILE; ')as txt from information_schema.tables where engine='Columnstore'" >> $TEMPSCRIPT
  mariadb -ABNe "select concat('echo \"USE ',TABLE_SCHEMA,';\" >> $SQLFILE; ','mariadb-dump ', TABLE_SCHEMA,' ',TABLE_NAME,' --no-data --skip-lock-tables --compact >> $SQLFILE')as txt from information_schema.tables where engine='Columnstore'" >> $TEMPSCRIPT
  chmod 750 $TEMPSCRIPT
# RUN THE TEMPSCRIPT:
  $TEMPSCRIPT
# ELIMINATE TABLE COMMENTS
  perl -p -i -e "s/ COMMENT=\'(.*?)\'//g" $SQLFILE
# ELIMINATE IN-LINE COMMENTS
  perl -p -i -e "s/\/\*(.*?)\*\/;//g" $SQLFILE
# ADD IN SHEMA SYNC ONLY
  perl -p -i -e "s/ENGINE=Columnstore/ENGINE=Columnstore COMMENT=\'SCHEMA SYNC ONLY\'/g" $SQLFILE
# ADD IF NOT EXISTS
  perl -p -i -e "s/CREATE TABLE/CREATE TABLE IF NOT EXISTS/g" $SQLFILE
# INFORM USER:
  echo "Please review the SQL file $SQLFILE before running it on the replica/slave."
}


function generate_sql_to_resync_columnstore_tables(){
ech0
TEMP_COLOR=lcyan; print_color "###### INDICATE CHARACTER SET #######\n"; unset TEMP_COLOR
ech0 "UTF8MB4 is a multi-byte character set. A varchar(2000) column, which is the maximum for UTF8MB4, can"
ech0 "store 2000 characters per string field, up to 8000 bytes. UTF8MB4 is contemporary and Columnstore's default."
ech0
ech0 "Latin1 is a single-byte character set. A varchar(8000) column, which is the maximum for Latin1, can"
ech0 "store 8000 characters per string field, up to 8000 bytes. Latin1 is legacy."
ech0 
ech0 "This script will generate SQL commands based on saved definitions of columnstore columns."
ech0 "Columnstore saves strings as bytes, not keeping information about the default character set of a table."
ech0 "Only the MariaDB dictionary stores the default character set. For these tables this detail has not been saved."
ech0
TEMP_COLOR=lgreen; print_color "Choose one of these options:\n"; unset TEMP_COLOR
TEMP_COLOR=lcyan; print_color "  1"; unset TEMP_COLOR; ech0 ") generate SQL to recreate tables as DEFAULT CHARSET=UTF8MB4"
TEMP_COLOR=lcyan; print_color "  2"; unset TEMP_COLOR; ech0 ") generate SQL to recreate tables as DEFAULT CHARSET=Latin1"

read yourchoice

case $yourchoice in
  1) echo "Option 1 chosen."; CHARSET='UTF8MB4';;
  2) echo "Option 2 chosen."; CHARSET='LATIN1';;
  *) exit 0;;
esac

  OUTPUTSQLFILE=/tmp/$(hostname)_resync_columnstore_tables_$CHARSET.sql
  echo "-- This SQL script was generated from columnstore_review.sh --schemasync" > $OUTPUTSQLFILE
  echo "-- By Edward Stoever for MariaDB Support" >> $OUTPUTSQLFILE
  echo "-- Please review this script carefully before running." >> $OUTPUTSQLFILE
  SQL="SELECT DISTINCT CONCAT('CREATE SCHEMA IF NOT EXISTS columnstore_review;') AS txt
       FROM information_schema.TABLES A
       INNER JOIN information_schema.COLUMNSTORE_TABLES B
       ON A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
       WHERE A.ENGINE<>'Columnstore';"
  mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE
  SQL="SELECT CONCAT('RENAME TABLE \`',A.TABLE_SCHEMA,'\`.\`',A.TABLE_NAME,'\` TO \`columnstore_review\`.\`',A.TABLE_NAME,'\`;') AS txt
       FROM information_schema.TABLES A
       INNER JOIN information_schema.COLUMNSTORE_TABLES B
       ON A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
       WHERE A.ENGINE<>'Columnstore';"
  mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE
if [ "$CHARSET" == "UTF8MB4" ]; then
  SQL="SELECT 
CONCAT('create table if not exists \`',TABLE_SCHEMA,'\`.\`',TABLE_NAME,'\` (', 
  GROUP_CONCAT('\`',COLUMN_NAME,'\` ',
    case DATA_TYPE 
    when 'medint' then CONCAT('mediumint')
    when 'int' then CONCAT('integer')
    when 'utinyint' then CONCAT('tinyint unsigned')
    when 'usmallint' then CONCAT('smallint unsigned')
    when 'umedint' then CONCAT('mediumint unsigned')
    when 'uint32_t' then CONCAT('integer unsigned')
    when 'ubigint' then CONCAT('bigint unsigned')
    when 'decimal' then CONCAT(DATA_TYPE,'(',NUMERIC_PRECISION,',',NUMERIC_SCALE,')')
    when 'varchar' then CONCAT(DATA_TYPE,'(',floor(COLUMN_LENGTH/4),')')
    when 'char' then CONCAT(DATA_TYPE,'(',floor(COLUMN_LENGTH/4),')')
    when 'text' then 
	   case COLUMN_LENGTH
	   when 255 then CONCAT('tinytext')
	   when 65535 then CONCAT('text')
	   ELSE CONCAT('longtext')
	   END
    when 'blob' then 
	   case COLUMN_LENGTH
	   when 255 then CONCAT('tinyblob')
	   when 65535 then CONCAT('blob')
	   ELSE CONCAT('longblob')
	   END
    else CONCAT(DATA_TYPE) 
	 END,
	 CONCAT(' DEFAULT ',COALESCE(CONCAT('''',COLUMN_DEFAULT,''''), 'NULL'))
  ORDER BY COLUMN_POSITION SEPARATOR ',')
,') ENGINE=columnstore DEFAULT CHARSET=utf8mb4 COMMENT=''SCHEMA SYNC ONLY'';') as txt
FROM information_schema.COLUMNSTORE_COLUMNS A 
WHERE NOT EXISTS
(SELECT 'x' FROM information_schema.TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
AND B.ENGINE='Columnstore')
GROUP BY TABLE_NAME
ORDER BY TABLE_SCHEMA, TABLE_NAME;"
fi 
if [ "$CHARSET" == "LATIN1" ]; then
  SQL="SELECT
CONCAT('create table if not exists \`',TABLE_SCHEMA,'\`.\`',TABLE_NAME,'\` (',
  GROUP_CONCAT('\`',COLUMN_NAME,'\` ',
    case DATA_TYPE
    when 'medint' then CONCAT('mediumint')
    when 'int' then CONCAT('integer')
    when 'utinyint' then CONCAT('tinyint unsigned')
    when 'usmallint' then CONCAT('smallint unsigned')
    when 'umedint' then CONCAT('mediumint unsigned')
    when 'uint32_t' then CONCAT('integer unsigned')
    when 'ubigint' then CONCAT('bigint unsigned')
    when 'decimal' then CONCAT(DATA_TYPE,'(',NUMERIC_PRECISION,',',NUMERIC_SCALE,')')
    when 'varchar' then CONCAT(DATA_TYPE,'(',COLUMN_LENGTH,')')
    when 'char' then CONCAT(DATA_TYPE,'(',COLUMN_LENGTH,')')
    when 'text' then
           case COLUMN_LENGTH
           when 255 then CONCAT('tinytext')
           when 65535 then CONCAT('text')
           ELSE CONCAT('longtext')
           END
    when 'blob' then
           case COLUMN_LENGTH
           when 255 then CONCAT('tinyblob')
           when 65535 then CONCAT('blob')
           ELSE CONCAT('longblob')
           END
    else CONCAT(DATA_TYPE)
         END,
         CONCAT(' DEFAULT ',COALESCE(CONCAT('''',COLUMN_DEFAULT,''''), 'NULL'))
  ORDER BY COLUMN_POSITION SEPARATOR ',')
,') ENGINE=columnstore DEFAULT CHARSET=latin1 COMMENT=''SCHEMA SYNC ONLY'';') as txt
FROM information_schema.COLUMNSTORE_COLUMNS A
WHERE NOT EXISTS
(SELECT 'x' FROM information_schema.TABLES B WHERE
A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
AND B.ENGINE='Columnstore')
GROUP BY TABLE_NAME
ORDER BY TABLE_SCHEMA, TABLE_NAME;"
fi

mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE
print0 "SQL script saved to $OUTPUTSQLFILE\n"
print0 "Review the SQL script before running.\n"
ech0
}

function generate_sql_to_delete_out_of_sync_columnstore_extents(){
  OUTPUTSQLFILE=/tmp/$(hostname)_delete_out_of_sync_columnstore_extents.sql
  echo "-- This SQL script was generated from columnstore_review.sh --schemasync" > $OUTPUTSQLFILE
  echo "-- By Edward Stoever for MariaDB Support" >> $OUTPUTSQLFILE
  echo "-- Please review this script carefully before running." >> $OUTPUTSQLFILE
  SQL="SELECT DISTINCT CONCAT('CREATE SCHEMA IF NOT EXISTS columnstore_review;') AS txt
       FROM information_schema.TABLES A
       INNER JOIN information_schema.COLUMNSTORE_TABLES B
       ON A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
       WHERE A.ENGINE<>'Columnstore';"
  mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE
  SQL="SELECT CONCAT('RENAME TABLE \`',A.TABLE_SCHEMA,'\`.\`',A.TABLE_NAME,'\` TO \`columnstore_review\`.\`',A.TABLE_NAME,'\`;') AS txt
       FROM information_schema.TABLES A
       INNER JOIN information_schema.COLUMNSTORE_TABLES B
       ON A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
       WHERE A.ENGINE<>'Columnstore';"
  mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE

  SQL="SELECT
       CONCAT('drop table if exists \`',TABLE_SCHEMA,'\`.\`',TABLE_NAME,'\`;') as txt
       FROM information_schema.COLUMNSTORE_COLUMNS A
       WHERE NOT EXISTS
      (SELECT 'x' FROM information_schema.TABLES B WHERE
       A.TABLE_SCHEMA=B.TABLE_SCHEMA AND A.TABLE_NAME=B.TABLE_NAME
       AND B.ENGINE='Columnstore')
      GROUP BY TABLE_NAME
      ORDER BY TABLE_SCHEMA, TABLE_NAME;"
  mariadb -ABNe "$SQL" >> $OUTPUTSQLFILE
  print0 "SQL script saved to $OUTPUTSQLFILE\n"
  print0 "Review the SQL script before running.\n"
  ech0

}

function ensure_owner_privs_of_tmp_dir() {
  if [ ! "$EUID" == "0" ]; then ech0 "This routine must be run as root."; return; fi
  ls /usr/bin/mariadb-columnstore-start.sh 1>/dev/null 2>/dev/null && CS_INSTALLED=true
  if [ ! $CS_INSTALLED ]; then return; fi

  TMP_DIR=$(mcsGetConfig SystemConfig SystemTempFileDir)
  SOMETHING_EXISTS=$(stat -c '%F' $TMP_DIR 2>/dev/null)
  if [ ! "$SOMETHING_EXISTS" == "directory" ] && [ ! -z "$SOMETHING_EXISTS" ]; then ech0 "$TMP_DIR exists but it is a $SOMETHING_EXISTS."; return; fi 
  if [ -d $TMP_DIR ]; then
    DIR_OWNER=$(stat -c '%U' $TMP_DIR)
	DIR_OCTAL=$(stat -c '%a' $TMP_DIR)
  fi
  BASE_DIR=$(ech0 $TMP_DIR | cut -d "/" -f2)
  
  if [ ! -d $TMP_DIR ]||[ ! "$DIR_OWNER" == "mysql" ]||[ ! "$DIR_OCTAL" == "755" ]; then 
    mkdir -p $TMP_DIR; 
    chown -R mysql:mysql $TMP_DIR; 
    chmod 755 $TMP_DIR; 
    ech0 "Created or modified directory $TMP_DIR with correct ownership and access rights.";
  fi

  PM1=$(mcsGetConfig pm1_WriteEngineServer IPAddr)
  PM2=$(mcsGetConfig pm2_WriteEngineServer IPAddr)
  if [ ! "$PM1" == "127.0.0.1" ] && [ ! -z $PM2 ]; then THISISCLUSTER=true; fi
  if [ ! "$THISISCLUSTER" ]; then ech0 "This is not a columnstore cluster. This solution is necessary for Columnstore Clusters only."; return; fi

  if [ ! -d /etc/tmpfiles.d ] && [ ! -d /usr/lib/tmpfiles.d ]; then 
    ech0 "Check whether this OS supports systemd-tmpfiles management of volatile and temporary files."; return;
  fi

  if [ -d /etc/tmpfiles.d ]; then 
    DIR1=true; 
    ALREADY_CONFIG=$(find /etc/tmpfiles.d -type f | xargs grep -l $TMP_DIR | head -1)
  fi
  if [ -d /usr/lib/tmpfiles.d ]; then 
    DIR2=true; 
	if [ -z $ALREADY_CONFIG ]; then
      ALREADY_CONFIG=$(find /usr/lib/tmpfiles.d -type f | xargs grep -l $TMP_DIR | head -1)
    fi
  fi

  if [ ! -z "$ALREADY_CONFIG" ]; then ech0 "The configuration has been completed already. Check the file $ALREADY_CONFIG"; return; fi
  
  if [ $DIR1 ]; then
    echo "d $TMP_DIR 0755 mysql mysql" > /etc/tmpfiles.d/columnstore_tmp_files.conf
	ech0 "Created the file /etc/tmpfiles.d/columnstore_tmp_files.conf"
  elif [ $DIR2 ]; then
    echo "d $TMP_DIR 0755 mysql mysql" > /usr/lib/tmpfiles.d/columnstore_tmp_files.conf
	ech0 "Created the file /usr/lib/tmpfiles.d/columnstore_tmp_files.conf"
  fi
  
}

function display_outputfile_message() {
  echo "The output of this script is saved in the file $OUTPUTFILE"; echo;
}

function display_help_message() {
  DATA1DIR=$(mcsGetConfig SystemConfig DBRoot1 2>/dev/null) || DATA1DIR=/var/lib/columnstore/data1
  COLUMNSTOREDIR=$(dirname $DATA1DIR) || COLUMNSTOREDIR=/var/lib/columnstore
  print_color "### HELP ###\n"
  print0 "This script is intended to be run while logged in as root. 
If database is up, this script will connect as root@localhost via socket.

Switches:
   --help            # display this message
   --version         # only show the header with version information
   --logs            # create a compressed archive of logs for MariaDB Support Ticket
   --backupdbrm      # takes a compressed backup of extent map files in dbrm directory
   --testschema      # creates a test schema, tables, imports, queries, drops schema
   --emptydirs       # searches $COLUMNSTOREDIR for empty directories
   --notmysqldirs    # searches $COLUMNSTOREDIR for directories not owned by mysql
   --emcheck         # Checks the extent map for orphaned and missing files
   --pscs            # Adds the pscs command. pscs lists running columnstore processes 
   --schemasync      # Fix out-of-sync columnstore tables (CAL0009)
   --tmpdir          # Ensure owner of temporary dir after reboot (MCOL-4866 & MCOL-5242)

Color output switches:
   --color=none      # print headers without color
   --color=red       # print headers in red
   --color=blue      # print headers in blue
   --color=green     # print headers in green
   --color=yellow    # print headers in yellow
   --color=magenta   # print headers in magenta
   --color=cyan      # print headers in cyan (default color)
   --color=lred      # print headers in light red
   --color=lblue     # print headers in light blue
   --color=lgreen    # print headers in light green
   --color=lyellow   # print headers in light yellow
   --color=lmagenta  # print headers in light magenta
   --color=lcyan     # print headers in light cyan\n"
  ech0
}

function ech0() {
 echo "$1"
 echo "$1" >> $OUTPUTFILE
}

function print0() {
 printf "$1"
 printf "$1" >> $OUTPUTFILE
}

function print_color () {
  if [ -z "$COLOR" ] && [ -z "$TEMP_COLOR" ]; then printf "$1"; printf "$1" >> $OUTPUTFILE; return; fi
  case "$COLOR" in
    default) i="0;36" ;;
    red)  i="0;31" ;;
    blue) i="0;34" ;;
    green) i="0;32" ;;
    yellow) i="0;33" ;;
    magenta) i="0;35" ;;
    cyan) i="0;36" ;;
    lred) i="1;31" ;;
    lblue) i="1;34" ;;
    lgreen) i="1;32" ;;
    lyellow) i="1;33" ;;
    lmagenta) i="1;35" ;;
    lcyan) i="1;36" ;;
    *) i="0" ;;
  esac
if [ $TEMP_COLOR ]; then
  case "$TEMP_COLOR" in
    default) i="0;36" ;;
    red)  i="0;31" ;;
    blue) i="0;34" ;;
    green) i="0;32" ;;
    yellow) i="0;33" ;;
    magenta) i="0;35" ;;
    cyan) i="0;36" ;;
    lred) i="1;31" ;;
    lblue) i="1;34" ;;
    lgreen) i="1;32" ;;
    lyellow) i="1;33" ;;
    lmagenta) i="1;35" ;;
    lcyan) i="1;36" ;;
    *) i="0" ;;
  esac
fi

  printf "\033[${i}m${1}\033[0m"
  printf "$1" >> $OUTPUTFILE
}

COLOR=default
for params in "$@"; do
  unset VALID;
  if [ "$params" == '--color=none' ]; then unset COLOR; VALID=true; fi
  if [ "$params" == '--color=red' ]; then COLOR=red; VALID=true; fi
  if [ "$params" == '--color=blue' ]; then COLOR=blue; VALID=true; fi
  if [ "$params" == '--color=green' ]; then COLOR=green; VALID=true; fi
  if [ "$params" == '--color=yellow' ]; then COLOR=yellow; VALID=true; fi
  if [ "$params" == '--color=magenta' ]; then COLOR=magenta; VALID=true; fi
  if [ "$params" == '--color=cyan' ]; then COLOR=cyan; VALID=true; fi
  if [ "$params" == '--color=lred' ]; then COLOR=lred; VALID=true; fi
  if [ "$params" == '--color=lblue' ]; then COLOR=lblue; VALID=true; fi
  if [ "$params" == '--color=lgreen' ]; then COLOR=lgreen; VALID=true; fi
  if [ "$params" == '--color=lyellow' ]; then COLOR=lyellow; VALID=true; fi
  if [ "$params" == '--color=lmagenta' ]; then COLOR=lmagenta; VALID=true; fi
  if [ "$params" == '--color=lcyan' ]; then COLOR=lcyan; VALID=true; fi
  if [ "$params" == '--color=cyan' ]; then COLOR=cyan; VALID=true; fi
  if [ "$params" == '--help' ]; then HELP=true; VALID=true; fi
  if [ "$params" == '--version' ]; then if [ ! $SKIP_REPORT ]; then DISPLAY_VERSION=true; fi; VALID=true; fi
  if [ "$params" == '--logs' ];    then if [ ! $SKIP_REPORT ]; then COLLECT_LOGS=true;    fi; VALID=true; fi
  if [ "$params" == '--backupdbrm' ]; then BACKUP_DBRM=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--testschema' ]; then TEST_SCHEMA=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--emptydirs' ]; then EMPTY_DIRS=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--notmysqldirs' ]; then NOT_MYSQL_DIRS=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--emcheck' ]; then EM_CHECK=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--pscs' ]; then PSCS_ALIAS=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--schemasync' ]; then SCHEMA_SYNC=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ "$params" == '--tmpdir' ]; then FIX_TMP_DIR=true; SKIP_REPORT=true; unset COLLECT_LOGS; VALID=true; fi
  if [ ! $VALID ]; then  INVALID_INPUT=$params; fi
done

prepare_for_run
exists_client_able_to_connect_with_socket
if [ $DISPLAY_VERSION ]; then exit 0; fi
if [ $INVALID_INPUT ]; then TEMP_COLOR=lred; print_color "Invalid parameter: ";ech0 $INVALID_INPUT; ech0; unset TEMP_COLOR; fi
if [ $HELP ]||[ $INVALID_INPUT ]; then
  display_help_message
  exit 0
fi
if [ ! $SKIP_REPORT ]; then
exists_error_log

exists_cs_error_log
exists_columnstore_running
exists_mariadb_installed
exists_columnstore_installed
exists_cmapi_installed
exists_cmapi_running
exists_mariadbd_running
exists_https_proxy
exists_cmapi_cert_expired
exists_zombie_processes
exists_iptables_rules
exists_ip6tables_rules
exists_mysql_user_with_proper_uid
exists_columnstore_tmp_files_wrong_owner
exists_selinux_not_disabled
exists_corefiles
exists_replica_not_started
exists_querystats_enabled
exists_diskbased_hashjoin
exists_crossenginesupport
exists_minimal_columnstore_running
exists_history_of_delete_dml
exists_history_of_update_dml
exists_history_of_file_does_not_exist
exists_compression_header_errors
exists_error_opening_file
exists_readtomagic_errors
exists_bad_magic_errors
exists_got_signal_errors
exists_errors_pushing_config
exists_history_failed_getSystemState
exists_does_not_exist_in_columnstore
exists_data1_dir_wrong_access_rights
exists_systemFiles_dir_wrong_access_rights
exists_holding_table_lock
exists_any_idb_errors
exists_cpu_unsupported_2208
exists_symbolic_links_in_columnstore_dir
exists_schema_out_of_sync
exists_columnstore_tables_with_no_extents

TEMP_COLOR=lblue; print_color "===================== HOST =====================\n"; unset TEMP_COLOR
report_machine_architecture
report_cpu_info
report_memory_info
report_disk_space
report_uptime
report_local_hostname_and_ips
report_top_for_mysql_user
report_listening_procs
TEMP_COLOR=lblue; print_color "===================== MARIADB =====================\n"; unset TEMP_COLOR
report_versions
report_slave_hosts
report_slave_status
report_db_processes
report_datadir_size
TEMP_COLOR=lblue; print_color "===================== COLUMNSTORE =====================\n"; unset TEMP_COLOR
report_topology
report_dbroots
report_storage_type
report_columnstore_mounts
report_brm_saves_current
report_cs_table_locks
report_columnstore_query_count
report_calpontsys_exists
report_columnstore_tables
TEMP_COLOR=lblue; print_color "===================== LOGS =====================\n"; unset TEMP_COLOR
report_host_datetime
report_last_10_error_log_error
report_last_5_columnstore_err_log
TEMP_COLOR=lblue; print_color "===================== WARNINGS =====================\n"; unset TEMP_COLOR
report_warnings
fi

if [ $COLLECT_LOGS ]; then
  collect_logs
else
  if [ ! $SKIP_REPORT ]; then display_outputfile_message; fi
fi

if [ $BACKUP_DBRM ]; then
  backup_dbrm
fi

if [ $TEST_SCHEMA ]; then
  create_test_schema
fi

if [ $EMPTY_DIRS ]; then
  empty_directories
fi

if [ $NOT_MYSQL_DIRS ]; then
  not_mysql_directories
fi

if [ $EM_CHECK ]; then
  extent_map_check
fi

if [ $PSCS_ALIAS ]; then
  add_pscs_alias
fi

if [ $SCHEMA_SYNC ]; then
  schema_sync
fi

if [ $FIX_TMP_DIR ]; then
  ensure_owner_privs_of_tmp_dir
fi

