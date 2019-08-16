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
    envdir /home/postgres/etc/wal-e.d/env wal-g backup-fetch $PGROOT/data/ LATEST
    chown -R postgres:postgres "$PGHOME"
    chmod 0700 $PGROOT/data/
    su postgres -c "rm -f $PGROOT/data/backup_label && mkdir -p $PGROOT/data/pg_wal/archive_status/ \
                    && $(which pg_resetwal) -f $PGROOT/data/ \
                    && $(which pg_ctl) start -D $PGROOT/data/"
    for i in $(seq 0 5); do
        su postgres -c "$(which pg_isready)" && STATUS="OK" || STATUS="FAILED"
        [[ "$STATUS" != "OK" ]] && sleep 20
    done
    
    su postgres -c "$(which pg_isready)" && STATUS="OK" || STATUS="FAILED"
    TS_STOP=$(date +%s)
    DURATION=$(($TS_STOP-$TS_START))
    echo "Latest postgresql backup check from $WALE_S3_PREFIX \nTIME: $DURATION sec."
    
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
