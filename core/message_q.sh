#
# Copyright © 2020 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

message_q_usage()
{
	cat<<-\EOT
This file exposes two message queues so that the main process can communicate
with child processes.
The main process (master) pushes tasks into 'single-writer multiple-readers'
queue. The child may read tasks from this queue and report its status into
'single-reader multiple-writers' queue which in turn read by the master.

All read and write operations are blocking. This is an application responsibility 
to implement communication protocol without interlocking.

    MASTER                                      SLAVE

    master_create                               slave_create

    for numWorkers
        run-worker-in-background &        /---> slave_init_taskPump
    done                                  |
                                       unblock
    for numWorkers                        |
        master_write_task $initialTask ---/     
    done
                                                while true; do
                                                    slave_read_task
                                                    [[ task == EOF ]] && break
                                                    execute_task
                                           ----     slave_write_status
    master_init_statusPump <--- unblock --/     done

    for numTasks
        master_read_status
        master_write_task
    done

    for numWorkers
        master_write_task EOF
    done

    master_destroy
EOT
}

PIPE_STATUS=
PIPE_TASK=
PIPE_LOGGER=
master_create()
{
    PIPE_LOGGER=${1:-}
    export PIPE_STATUS=/tmp/mq_status.$$
    export PIPE_TASK=/tmp/mq_task.$$
    for REPLY in $PIPE_STATUS $PIPE_TASK; do
        rm -f -- $REPLY
        mkfifo $REPLY
        touch $REPLY.lock
    done
}
master_destroy()
{
    rm -f -- $PIPE_STATUS
    rm -f -- $PIPE_TASK
}
master_init_statusPump()
{
    exec 9<$PIPE_STATUS
}
master_read_status()
{
    while ! read -r -u 9; do :; done
}
master_write_task()
{
    echo "$1" >$PIPE_TASK
}

slave_create()
{
    PIPE_LOGGER=${1:-}
}
slave_init_taskPump()
{
    exec 9<$PIPE_TASK
}
slave_read_task()
{
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "r task lock open";     exec 8>$PIPE_TASK.lock    
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "r task lock";          flock 8
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "r task locked";        while ! read -r -u 9; do :; done
    local msg=$REPLY
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "r task read [$msg]";   flock -u 8
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "r task unlocked";      exec 8<&-
    REPLY=$msg
}
slave_write_status()
{
    local msg=$1
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status [$msg]";
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status lock open";   exec 8>$PIPE_STATUS.lock
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status lock]";       flock 8
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status locked";      echo "$msg" > $PIPE_STATUS
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status write";       flock -u 8
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status written";     exec 8<&-
    [[ -n "$PIPE_LOGGER" ]] && $PIPE_LOGGER "w status unlocked";    
}

if [[ "$(basename ${BASH_SOURCE-url.sh})" == "$(basename $0)" ]]; then
	message_q_usage "$@"
fi
