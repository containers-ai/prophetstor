# Federator.ai InfluxDB Backup/Restore Utility
Federator.ai uses InfluxDB to store time-series metrics of monitored resources. This script leverages the InfluxDB built-in backup/restore functions to back up the metrics databases into one backup file or restore the databases from a backup file.

The script uses `kubectl` to communicate with the Kubernetes cluster and InfluxDB. It can run in any Linux host where the `kubectl` is configured. The main features of the script include
- Back up and restore InfluxDB metrics databases remotely.
- Support InfluxDB databases full backup. (Incremental/Differential backup is not supported.)
- Encrypt/Decrypt backup (by `openssl`).
- Dry run mode simulates the backup/restore process without affecting InfluxDB.
- Available to integrate with a cronjob to create backups by schedule.
- Decrypt and extract a backup without actually restoring it to InfluxDB.

## Requirement
- Linux/x86_64 host with at least 30GB free space.
- `kubectl` is configured with permissions to run commands in Federator.ai pods.
- The usage of Federator.ai InfluxDB's 'data' persistent volume is lower than 75%.
- `openssl` is optional for encrypting/decrypting backups.
 
## Backup
The script uses `kubectl` to run InfluxDB backup in Federator.ai InfluxDB container. Once the backup is done, the script downloads the backup from Federator.ai InfluxDB container and packs/encrypts the backup into a local backup file.

A backup info file that includes the backup version, Federator.ai version, cluster name, backup time, and md5 checksum is created for the backup.
### Usage
```
influxdb-backup.sh backup [options]
```
### Options
```
  -x, --context=''       Kubeconfig context name (DEFAULT: '')
  -d, --dryrun=no        Dry run backup or restore (DEFAULT: 'no')
  -e, --encrypt=yes      Encrypt/Decrypt backup (DEFAULT: 'yes')
  -c, --directory=''     Working directory for storing backup files (DEFAULT: '.')
  -p, --password=''      Encryption/Decryption password (or read from 'INFLUX_BACKUP_PASSWORD')
  -l, --logfile=''       Log path/file (DEFAULT: '/var/log/influxdb-backup.log')
  -n, --cleanup=yes      (For debugging) clean up/revert operations have been done (DEFAULT: 'yes')
```
### Example
```
$ influxdb-backup.sh backup
Federator.ai InfluxDB Backup/Restore Utility v1.0.1

Start creating backup for 'h2-63.prophetservice.com'. It will take several minutes to complete.
Enter InfluxDB backup password (at least 8 characters): 

Successfully created backup 'backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC.backup.enc'.
The backup time elapsed is 88 seconds.
```

## Restore
The script decrypts/unpacks the backup file and uses `kubectl` to upload the backup to Federator.ai InfluxDB container and restore from the backup.

The restore operation is destructive. It will stop Federator.ai pods and drop all existing databases. After restoration, Federator.ai InfluxDB pod will be restarted and other Federator.ai pods will then be started. 
### Usage
```
influxdb-backup.sh restore <backup_file> [options]
```
### Options
```
  -x, --context=''       Kubeconfig context name (DEFAULT: '')
  -d, --dryrun=no        Dry run backup or restore (DEFAULT: 'no')
  -e, --encrypt=yes      Encrypt/Decrypt backup (DEFAULT: 'yes')
  -c, --directory=''     Working directory for storing backup files (DEFAULT: '.')
  -f, --force=no         Restore the backup to a different Federator.ai cluster
  -p, --password=''      Encryption/Decryption password (or read from 'INFLUX_BACKUP_PASSWORD')
  -u, --alwaysup=no      Always scale up Federator.ai deployments (DEFAULT: 'no')
  -l, --logfile=''       Log path/file (DEFAULT: '/var/log/influxdb-backup.log')
  -n, --cleanup=yes      (For debugging) clean up/revert operations have been done (DEFAULT: 'yes')
```
### Example
```
$ influxdb-backup.sh restore backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC.backup.enc
Federator.ai InfluxDB Backup/Restore Utility v1.0.1

 WARN: Restore databases to 'h2-63.prophetservice.com' will stop Federator.ai services and destroy existing data!

Do you want to proceed? Type 'YES' to confirm: YES
Do you want to create a backup before restoring databases?[Y|n] 

Start creating backup for 'h2-63.prophetservice.com'.
Enter InfluxDB backup password (at least 8 characters): 
Successfully created backup 'backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084903-UTC.backup.enc'.
Start restoring databases. It will take several minutes to complete.

Successfully restore Federator.ai InfluxDB databases from backup 'backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC.backup.enc'.
The restore time elapsed is 358 seconds.
```

## Extract
The script decrypts and extracts the backup to a local directory without any communications with Federator.ai.
### Usage
```
influxdb-backup.sh restore <backup_file> [options]
```
### Options
```
  -x, --context=''       Kubeconfig context name (DEFAULT: '')
  -e, --encrypt=yes      Encrypt/Decrypt backup (DEFAULT: 'yes')
  -c, --directory=''     Working directory for storing backup files (DEFAULT: '.')
  -p, --password=''      Encryption/Decryption password (or read from 'INFLUX_BACKUP_PASSWORD')
  -l, --logfile=''       Log path/file (DEFAULT: '/var/log/influxdb-backup.log')
  -n, --cleanup=yes      (For debugging) clean up/revert operations have been done (DEFAULT: 'yes')
```
### Example
```
$ influxdb-backup.sh extract backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC.backup.enc
Federator.ai InfluxDB Backup/Restore Utility v1.0.1

Start extracting backup 'backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC.backup.enc'.
Enter InfluxDB backup password (at least 8 characters): 

Version=1.0.1
Federatorai=5.1.1
Cluster=h2-63.prophetservice.com
Time=20230109-084309-UTC
MD5=91ce34eb42dd6d5baa272f0b814b2bbd

Successfully extract backup to 'backup/InfluxDB-backup-h2-63.prophetservice.com-20230109-084309-UTC'.
The extract time elapsed is 17 seconds.
```
