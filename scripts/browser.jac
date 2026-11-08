"""Run pinned Jac browser commands with the verified startup-ordering fix."""
import sys;
import jaclang.cli.browser_engine as browser_engine;
import from scripts.prepare_jac { prepare_browser_runtime }

with entry:__main__ {
    prepare_browser_runtime();
    sys.`exit(browser_engine.main(sys.argv[1:]));
}
