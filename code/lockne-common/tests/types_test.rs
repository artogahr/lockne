use lockne_common::{Pid, PolicyEntry};

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

#[test]
fn test_policy_entry_default() {
    let entry = PolicyEntry::default();
    assert_eq!(entry.ifindex, 0);
    assert_eq!(entry.flags, 0);
}

#[test]
fn test_policy_entry_size() {
    // PolicyEntry should be 8 bytes (2 x u32)
    assert_eq!(std::mem::size_of::<PolicyEntry>(), 8);
}

#[test]
fn test_policy_entry_values() {
    let entry = PolicyEntry {
        ifindex: 42,
        flags: 1,
    };
    assert_eq!(entry.ifindex, 42);
    assert_eq!(entry.flags, 1);
}