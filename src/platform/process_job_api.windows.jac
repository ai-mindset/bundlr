"""A named Windows job contains the runner before it starts any build code."""
import from .kernel32 {
    obj JobLimits {
        has process_time: i64,
            job_time: i64,
            flags: u32,
            minimum_working_set: u64,
            maximum_working_set: u64,
            process_limit: u32,
            affinity: u64,
            priority: u32,
            scheduling: u32,
            read_operations: u64,
            write_operations: u64,
            other_operations: u64,
            read_bytes: u64,
            write_bytes: u64,
            other_bytes: u64,
            process_memory_limit: u64,
            job_memory_limit: u64,
            peak_process_memory: u64,
            peak_job_memory: u64;
    }  obj JobAccounting {
        has user_time: i64,
            kernel_time: i64,
            period_user_time: i64,
            period_kernel_time: i64,
            page_faults: u32,
            total_processes: u32,
            active_processes: u32,
            terminated_processes: u32;
    }  def CreateJobObjectA(attributes: ptr, name: str) -> ptr;  def OpenJobObjectA(
        access: u32, inherit: i32, name: str
    ) -> ptr;  def SetInformationJobObject(
        job: ptr, kind: i32, limits: &JobLimits, size: u32
    ) -> i32;  def QueryInformationJobObject(
        job: ptr, kind: i32, accounting: &mut JobAccounting, size: u32, returned: ptr
    ) -> i32;  def AssignProcessToJobObject(job: ptr, process: ptr) -> i32;  def TerminateJobObject(
        job: ptr, code: u32
    ) -> i32;  def GetCurrentProcess -> ptr;  def CloseHandle(handle: ptr) -> i32;  def GetLastError -> u32;
}

def checked_windows(result: i32, operation: str) {
    if result == 0 {
        raise RuntimeError(operation + ": Windows error " + str(GetLastError()));
    }
}

def:pub terminate_job(handle: ptr) {
    checked_windows(TerminateJobObject(handle, 1), "Terminate build process tree");
}

def:pub job_empty(handle: ptr) -> bool {
    accounting = JobAccounting();
    checked_windows(
        QueryInformationJobObject(handle, 1, &mut accounting, 48, ptr()),
        "Wait for build process tree"
    );
    return accounting.active_processes == 0;
}

def:pub close_job(handle: ptr) {
    CloseHandle(handle);
}

def:pub create_job(name: str) -> ptr {
    handle = CreateJobObjectA(ptr(), name);
    if handle.is_null() {
        raise RuntimeError("Could not create build process job.");
    }
    try {
        # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, without either breakaway flag.
        limits = JobLimits(flags=8192);
        checked_windows(
            SetInformationJobObject(handle, 9, &limits, 144),
            "Configure build process job"
        );
        return handle;
    } except Exception {
        CloseHandle(handle);
        raise;
    }
}

def:pub enter_job(name: str) {
    handle = OpenJobObjectA(1, 0, name);
    if handle.is_null() {
        raise RuntimeError("Could not open build process job.");
    }
    try {
        checked_windows(
            AssignProcessToJobObject(handle, GetCurrentProcess()),
            "Join build process job"
        );
    } finally {
        CloseHandle(handle);
    }
}
