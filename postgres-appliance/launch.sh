#!/bin/sh

if [ -f /a.tar.xz ]; then
    echo "decompressing spilo image..."
    if tar xpJf /a.tar.xz -C / > /dev/null 2>&1; then
        rm /a.tar.xz
        ln -snf dash /bin/sh
    else
        echo "failed to decompress spilo image"
        exit 1
    fi
fi

if [ "$DEMO" != "true" ]; then
    pgrep supervisord > /dev/null && echo "ERROR: Supervisord is already running" && exit 1
fi

mkdir -p "$PGLOG"

## Ensure all logfiles exist, most appliances will have
## a foreign data wrapper pointing to these files
for i in $(seq 0 7); do
    if [ ! -f "${PGLOG}/postgresql-$i.csv" ]; then
        touch "${PGLOG}/postgresql-$i.csv"
    fi
done
chown -R postgres:postgres "$PGHOME"

if [ "$CHECKBACKUP" = "true" ]; then
    TS_START=$(date +%s)
    python3 /scripts/configure_spilo.py wal-e certificate
    LATEST_BACKUP=$(envdir /home/postgres/etc/wal-e.d/env wal-g backup-list | tail -1 )
    envdir /home/postgres/etc/wal-e.d/env wal-g backup-fetch $PGDATA LATEST

cat <<EOF > $PGDATA/recovery.conf
restore_command = 'envdir "/home/postgres/etc/wal-e.d/env" /scripts/restore_command.sh "%f" "%p"'
recovery_target_timeline = 'immediate'
EOF
    sed -i "s/^archive_mode.*/archive_mode\ =\ 'off'/g" $PGDATA/postgresql.conf
    sed -i "s/^archive_command.*/archive_command\ =\ '\/bin\/true'/g" $PGDATA/postgresql.conf

    chown -R postgres:postgres "$PGHOME"
    chmod 0700 $PGDATA
    su postgres -c "$(which pg_ctl) start -D $PGDATA"
    STATUS="FAILED"
    for i in $(seq 0 10); do
        su postgres -c "$(which pg_isready)" && STATUS="OK" || sleep 60
    done

    TS_STOP=$(date +%s)
    DURATION=$(($TS_STOP-$TS_START))
    BACKUP_ID=$(echo $LATEST_BACKUP | cut -d " " -f1)
    BACKUP_MODTIME=$(echo $LATEST_BACKUP | cut -d " " -f2)
    BACKUP_SIZE=$(du -sh $PGDATA | cut -d"/" -f1)

    INFO_TEXT="Latest postgresql backup check from $WALE_S3_PREFIX \n\
    backup id: $BACKUP_ID \n\
    backup size: $BACKUP_SIZE \n\
    modification time: $BACKUP_MODTIME\n\
    duration: $DURATION sec."
    echo -e "$INFO_TEXT"

    if [[ ! -z "$SLACKNOTIFYURL" ]]; then
        SLACK_TITLE="backup check status: $STATUS"

        [[ "$STATUS" = "OK" ]] && SLACK_COLOR="good" || SLACK_COLOR="danger"

        PAYLOAD="{\"username\":\"$SLACKUSERNAME\",\"channel\":\"$SLACKCHANNEL\",\"icon_emoji\":\":moyai:\",\"attachments\":[{\"title\":\"$SLACK_TITLE\",\"color\":\"$SLACK_COLOR\",\"text\":\"$INFO_TEXT\",\"ts\":$TS_START}]}"
        curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" $SLACKNOTIFYURL
    fi

    if [[ ! -z "$OPSGENIEBACKUPHOOKURI" ]] && [[ ! -z "$OPSGENIEBACKUPHOOKKEY" ]]; then
        curl -s -X GET "$OPSGENIEBACKUPHOOKURI" --header "Authorization: GenieKey $OPSGENIEBACKUPHOOKKEY"
    fi

    su postgres -c "$(which pg_ctl) stop -D $PGDATA"
    rm -rf $PGHOME/*

elif [ "$DEMO" = "true" ]; then
    sed -i '/motd/d' /root/.bashrc
    python3 /scripts/configure_spilo.py patroni patronictl certificate pam-oauth2
    (
        su postgres -c 'env -i PGAPPNAME="pgq ticker" /scripts/patroni_wait.sh --role master -- /usr/bin/pgqd /home/postgres/pgq_ticker.ini'
    ) &
    exec su postgres -c "PATH=$PATH exec patroni /home/postgres/postgres.yml"
else
    if python3 /scripts/configure_spilo.py all; then
        (
            su postgres -c "PATH=$PATH /scripts/patroni_wait.sh -t 3600 -- envdir $WALE_ENV_DIR /scripts/postgres_backup.sh $PGDATA $BACKUP_NUM_TO_RETAIN"
        ) &
    fi
    exec supervisord --configuration=/etc/supervisor/supervisord.conf --nodaemon
fi
