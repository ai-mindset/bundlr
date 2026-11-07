"""Job lifetime shared across platforms; Unix subprocesses use process groups."""
import from src.platform.files { random_token }
import from src.platform.process_job_api {
    create_job,
    terminate_job,
    job_empty,
    close_job,
    enter_job
}

obj:pub ProcessJob {
    has name: str = "",
        handle: ptr = ptr();

    def terminate {
        if not self.handle.is_null() {
            terminate_job(self.handle);
        }
    }

    def empty -> bool {
        return job_empty(self.handle);
    }

    def close {
        if not self.handle.is_null() {
            close_job(self.handle);
            self.handle = ptr();
        }
    }
}

def:pub create_process_job -> ProcessJob {
    job = ProcessJob(name="Local\\Bundlr-" + random_token());
    job.handle = create_job(job.name);
    return job;
}

def:pub enter_process_job(name: str) {
    enter_job(name);
}
