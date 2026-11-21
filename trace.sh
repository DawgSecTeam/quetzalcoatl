nohup bpftrace -e '
tracepoint:syscalls:sys_enter_execve
{
    $task = (struct task_struct *)curtask;
    time("%H:%M:%S ");
    printf("%-16s UID:%-6d PID:%-6d PPID:%-6d ", comm, uid, pid, $task->real_parent->pid);
    join(args.argv);
}' | grep -v "watchdawg" > /var/tmp/execsnoop.log 2>&1 &
