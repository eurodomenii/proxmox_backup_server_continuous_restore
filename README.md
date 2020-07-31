# Rationale

1. The true High Availability with Proxmox VE could be achieved with network distributed storage, like Ceph. But, compared with local storage, there’s a performance penalty, even with 10G network.

2. A better balanced solution is  https://pve.proxmox.com/wiki/Storage_Replication ( with a COW filesystem like ZFS/BTRFS). The storage is local, but the  replication uses snapshots to minimize traffic sent over the network.  Therefore, new data is sent only incrementally after the initial full sync, with send receive feature between snapshots. The true advantage is that the replicated remote node doesn’t need to restore the VM, the diff snapshot is ready to be online in case of production downtime, acting as a hot standby, synchronized as low as 15 min. From my benchmarks, with a hundred GB VM, the ZFS/BTRFS send receive of incremental is blazing fast ( matter of minutes). 

3. Still, the best performance is with a local non COW storage ( because copy on write  file systems like ZFS/BTRFS are not the best suited for virtualization or databases). Best choice would be LVM-thin on mdadm, in order to have local snapshots feature. See my results from comparative phoronix suites tests: https://openbenchmarking.org/result/2007127-EURO-200712128

	**The use case is a production Proxmox server sending incremental backups via proxmox backup server to a remote datastore on another Proxmox backup server. The other Proxmox backup server would act as a hot standby. In case of downtime of the production server, the failover IPs should be rerouted to the hot standby server.**

	There’s a trade off for the maximum performance non cow storage. It needs restore on the remote server. 

	> Having incremental and deduplicated backups plus a very flexible pruning schedule available can allow one to make backups more often so one has always a recent state ready. via t.lamprecht Proxmox Staff Member  https://forum.proxmox.com/threads/proxmox-backup-server-beta.72677/page-2#post-324884 

	Now comes the need for the current proxmox backup server continuous restore script. For the Proxmox VE Backup server to behave as a hot standby,  we need a script to continuously restore on the remote server. It couldn’t be as synchronized as https://pve.proxmox.com/wiki/Storage_Replication, at 15 min, due to longer restore times. But, depending on the size of VMs, you could have up and running from several minutes to a few hours old version of production VMs , depending on the restore queue.

# Prerequisites

## Proxmox PVE & PBS
Proxmox backup server could be installed as a standalone product, but, in order to act as a hot standby for other Proxmox VE production server, it must be installed on top of Proxmox VE server. (See https://pbs.proxmox.com/docs/installation.html#install-proxmox-backup-server-on-proxmox-ve).  Proxmox-backup-client is already included in Proxmox VE.

## Other packers required: 

```
apt install jq
```

## Sample configuration
### Production server

```
root@melania:~# cat /etc/pve/storage.cfg
dir: local
        path /var/lib/vz
        content iso,snippets,vztmpl,rootdir,backup,images
        maxfiles 0
        shared 0

dir: sata
        path /ab/backup/eurodomenii
        content iso,images,backup
        maxfiles 0
        shared 0

lvmthin: local-lvm
        thinpool vmstore
        vgname vmdata
        content rootdir,images

pbs: max
        disable
        datastore melania
        server 192.168.7.158
        content backup
        fingerprint bc:9d:f7:b9:ce:d3:cd:07:2d:8f:d8:e4:99:2a:69:41:11:db:a5:4c:16:5f:5d:de:aa:42:55:ab:f2:65:99:bc
        maxfiles 0
        username melania@pbs

pbs: local_melania
        datastore store_melania
        server localhost
        content backup
        fingerprint 97:9c:cd:5b:a8:0d:67:84:53:fc:93:83:ea:dc:3e:83:d1:24:28:75:70:aa:cf:13:38:da:07:d0:51:be:eb:a4
        maxfiles 0
        username realmelania@pbs
```

### Remote Proxmox VE Backup server hot standby

```
root@max:/# cat /etc/pve/storage.cfg
dir: local
        path /var/lib/vz
        content iso,rootdir,backup,images,vztmpl,snippets
        maxfiles 0
        shared 0

lvmthin: local-lvm
        thinpool vmstore
        vgname vmdata
        content images,rootdir

pbs: melania
        datastore melania
        server localhost
        content backup
        fingerprint bc:9d:f7:b9:ce:d3:cd:07:2d:8f:d8:e4:99:2a:69:41:11:db:a5:4c:16:5f:5d:de:aa:42:55:ab:f2:65:99:bc
        maxfiles 0
        username melania@pbs

dir: sata
        path /var/eurodomenii/backup
        content vztmpl,snippets,images,rootdir,iso,backup
        maxfiles 0
        shared 0

```

# Usage

## Parameters

**--repository**

Format sample: --repository "myuser@pbs@localhost:store2"

**--password**

*Use single quotes for password to avoid exclamation mark issues in bash parameters.* 

Format sample: --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY'
	
**--prefix**

*The first digit of the VM-Container id*

Format sample: --prefix 4

## Sample single instance run 

### From cli

```
chmod +x /var/eurodomenii/scripts/pbs_continuous_restore/pbs_continuous_restore.pl
root@max:/# /var/eurodomenii/scripts/pbs_continuous_restore/pbs_continuous_restore.pl --repository melania@pbs@localhost:melania --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY'
```

### From Cron

This is the preferable setup. The script should run every minute, but there’s an app.lock file that prevents breaking the foreach loop through each VMids from the datastore.

```
root@max:/var/eurodomenii/scripts/pbs_continuous_restore# cat pbs_bash.sh
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
perl /var/eurodomenii/scripts/pbs_continuous_restore/pbs_continuous_restore.pl --repository melania@pbs@localhost:melania --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY'
```
```
root@max:/# crontab -l
* * * * * /var/eurodomenii/scripts/pbs_continuous_restore/pbs_bash.sh > /dev/null 2>&1
```

 ## Sequentially versus simultaneous restores

Normally, the restore process runs sequentially. This has a big advantage: since we choose to restore the latest version of an incremental backup, during the restore of a virtual machine, there’s a good chance that remote sync job will bring a newer incremental version for the next virtual machine in the continuous restore queue. Even the simultaneous restore has a slight time advantage, it’s a bad architecture to restore too many at once, from older incremental versions.

However, depending on the particular use cases, 2 or 3 threads of restoring might be the best balanced solution, prioritizing your clients.

This can be achieved running on cron, every minute, 2-3 instance of the script, in different directories, in order to avoid conflicts of app.lock file

Further, there’s 2 ways of doing it:
* either you run each script with a different repository parameter. *Can't do this, since at the moment there's not --password command line option, but only PBS_PASSWORD environment variable, that will be overridden by multiple scripts.*
* either you run each script with a different prefix parameter. ( by prefix meaning the first digit of the VM-Container id). *Using the first digit as a prefix is somehow a “dummy” solution. Instead, as a proxmox feature request, some kind of tagging of VM-Containers would be very useful!*

### Sample multiple instance run from cron

```
root@max:/# cat /var/eurodomenii/scripts/restore1/pbs_bash.sh
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
perl /var/eurodomenii/scripts/restore1/pbs_continuous_restore.pl --repository melania@pbs@localhost:melania --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY' --prefix 3
```

```
root@max:/# cat /var/eurodomenii/scripts/restore2/pbs_bash.sh
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
perl /var/eurodomenii/scripts/restore2/pbs_continuous_restore.pl --repository melania@pbs@localhost:melania --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY' --prefix 4
```

```
root@max:/# crontab -l
* * * * * /var/eurodomenii/scripts/restore1/pbs_bash.sh > /dev/null 2>&1
* * * * * /var/eurodomenii/scripts/restore2/pbs_bash.sh > /tmp/cronjob2.log 2>&1
```

**Tip**: check with *ps -aux | grep perl*  when running simultaneous process  

# Roadmap

## Todo
* Before stopping / destroying the VM, it would be better to restore to another id. In case that production server goes down and the restoring process is too long on the standby server, there would be the option to go online with a previous restored VM. For the moment is low priority, due to the burden of keeping track of the correlation between different stages of restore, for the same VM.

## Proxmox feature requests to improve workflow

* Can't run multiple instances of the script with different repositories, since at the moment there's no --password command line option, but only PBS_PASSWORD environment variable, that will be overridden.

* It would be helpful if the output format json-pretty would provide out of the box a snapshot field like text format, in order to avoid reconstruction.
