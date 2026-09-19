//! `EventQueue`: the bounded first-in first-out queue of events a loop produced itself and the
//! caller has not reaped yet: a timer that fired, a cancel that won before the kernel saw the
//! operation. Not written yet.
