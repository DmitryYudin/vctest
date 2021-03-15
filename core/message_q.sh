#
# Copyright © 2020 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

MQ_message_q_usage()
{
	cat<<-\EOT
This file exposes two message queues so that the main process can communicate
with child processes.
The main process (master) pushes tasks into 'single-writer multiple-readers'
queue. The child may read tasks from this queue and report its status into
'single-reader multiple-writers' queue which in turn read by the master.

All read and write operations are blocking. This is an application responsibility 
to implement communication protocol without interlocking.

MASTER() {                         /------>|SLAVE() {
                                   .       |
    master_create                  .       |    slave_create
                                   .       |
    # Run workers in a background  .       |
    for numWorkers                 .       |
        SLAVE & >------------------/ /-----|--> slave_init_taskPump
    done                             .     |
                                  unblock  |
    for numWorkers                   .     |
        master_write_task $task >----/     |     
    done                                   |
                                           |    while true; do
                                           |        slave_read_task
                                           |        [[ task == EOF ]] && break
                                           |        execute_task
                                           |------< slave_write_status
    master_init_statusPump <--- unblock --/|    done
                                           |}
    for numTasks
        master_read_status
        master_write_task $task
    done

    for numWorkers
        master_write_task EOF
    done

    master_destroy
}
EOT
}

MQ_PIPE_STATUS=
MQ_PIPE_TASK=
MQ_PIPE_LOGGER=
MQ_master_create()
{
    MQ_PIPE_LOGGER=${1:-}
    export MQ_PIPE_STATUS=/tmp/mq_status.$$
    export MQ_PIPE_TASK=/tmp/mq_task.$$
    for REPLY in $MQ_PIPE_STATUS $MQ_PIPE_TASK; do
        rm -f -- $REPLY
        mkfifo $REPLY
        touch $REPLY.lock
    done
}
MQ_master_destroy()
{
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I status destroy";     rm -f -- $MQ_PIPE_STATUS
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I status destroed";     
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I task destroy";       rm -f -- $MQ_PIPE_TASK
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I status destroed";     
}
MQ_master_init_statusPump()
{
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I status open";        exec 9<$MQ_PIPE_STATUS
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I status opened";     
}
MQ_master_read_status()
{
    local msg
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r status reading";     while ! read -r -u 9 msg; do :; done
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r status read [$msg]"
    REPLY=$msg
}
MQ_master_write_task()
{
    local msg=$1
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w task write [$msg]";  echo "$msg" >$MQ_PIPE_TASK
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w task written";
}

MQ_slave_create()
{
    MQ_PIPE_LOGGER=${1:-}
}
MQ_slave_init_taskPump()
{    
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I task open";          exec 9<$MQ_PIPE_TASK
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "I task opened";     
}
MQ_slave_read_task()
{
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r task lock open";     exec 8>$MQ_PIPE_TASK.lock    
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r task lock";          flock 8
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r task locked";        while ! read -r -u 9 msg; do :; done
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r task read [$msg]";   flock -u 8
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "r task unlocked";      exec 8<&-
    REPLY=$msg
}
MQ_slave_write_status()
{
    local msg=$1
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status [$msg]";
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status lock open";   exec 8>$MQ_PIPE_STATUS.lock
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status lock]";       flock 8
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status locked";      echo "$msg" > $MQ_PIPE_STATUS
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status write";       flock -u 8
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status written";     exec 8<&-
    [[ -n "$MQ_PIPE_LOGGER" ]] && $MQ_PIPE_LOGGER "w status unlocked";    
}

if [[ "$(basename ${BASH_SOURCE-message_q.sh})" == "$(basename $0)" ]]; then
	MQ_message_q_usage "$@"
fi
