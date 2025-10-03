use lockne_common::Pid;

#[test]
fn test_pid_type() {
    // Test that Pid is a u32
    let pid: Pid = 12345;
    assert_eq!(pid, 12345u32);
    
    // Test that it can hold typical PID values
    let max_pid: Pid = 4194304; // Typical max PID on Linux
    assert_eq!(max_pid, 4194304);
}

#[test]
fn test_pid_size() {
    // Ensure Pid is 32 bits
    assert_eq!(std::mem::size_of::<Pid>(), 4);
}