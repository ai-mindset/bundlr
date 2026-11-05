"""Browser behavior authored in Jac; compiled to a static ES module for the native server."""
glob config: any = JSON.parse(
         (document.getElementById("config") as any).textContent
     ),
     newline: str = chr(10),
     quitting: bool = False;

def control(id: str) -> any {
    return document.getElementById(id);
}

def auth(page: bool = False) -> any {
    headers = {"content-type": "application/json", "x-bundlr-token": config.token};
    if page {
        headers["x-bundlr-page"] = config.pageId;
    }
    return headers;
}

def output(stream: str, text: str) {
    span = document.createElement("span") as any;
    if stream == "stderr" {
        span.className = "stderr";
    }
    span.textContent = text;
    control("output").append(span);
    control("output").scrollTop = control("output").scrollHeight;
}

async def submit(event: any) {
    event.preventDefault();
    if quitting {
        return;
    }
    control("output").textContent = "";
    control("status").textContent = "Packaging application...";
    control("package").disabled = True;
    control("cancel").disabled = False;
    try {
        targets: list[str] = [];
        for item in (
            document.querySelectorAll('input[name="target"]:checked') as list[any]
        ) {
            targets.append(item.value);
        }
        response = await fetch(
            "/package",
            {
                "method": "POST",
                "headers": auth(),
                "body": JSON.stringify(
                    {
                        "source": control("source").value,
                        "applicationName": control("applicationName").value,
                        "command": control("command").value,
                        "applicationKind": control("applicationKind").value,
                        "python": control("python").value,
                        "outputDirectory": control("outputDirectory").value,
                        "targets": targets
                    }
                )
            }
        );
        if not response.ok or not response.body {
            raise Exception(await response.text());
        }
        reader = response.body.getReader();
        decoder = new(TextDecoder);
        pending = "";
        complete = False;
        while True {
            chunk = await reader.read();
            pending += decoder.decode(chunk.value, {"stream": not chunk.done});
            lines = pending.split(newline);
            pending = lines.pop();
            for line in lines {
                if not line {
                    continue;
                }
                message = JSON.parse(line) as any;
                if message.type == "output" {
                    output(message.stream, message.text);
                }
                if message.type == "error" {
                    raise Exception(message.message);
                }
                if message.type == "done" {
                    complete = True;
                    names: list[str] = [];
                    for result in message.results {
                        names.append(result.archivePath);
                    }
                    if not quitting {
                        control("status").textContent = "Created "
                            + ", ".join(names)
                            + ".";
                    }
                }
            }
            if chunk.done {
                break;
            }
        }
        if not complete {
            raise Exception("Packaging connection closed unexpectedly.");
        }
    } except Exception as error {
        if not quitting {
            control("status").textContent = "Error: " + (error as any).message;
        }
    } finally {
        if not quitting {
            control("package").disabled = False;
            control("cancel").disabled = True;
        }
    }
}

async def cancel(event: any) {
    control("status").textContent = "Cancelling...";
    await fetch("/cancel", {"method": "POST", "headers": auth()});
}

async def quit(event: any) {
    quitting = True;
    await fetch("/quit", {"method": "POST", "headers": auth()});
    clearInterval(heartbeat);
    for item in (document.querySelectorAll("button, input, select") as list[any]) {
        item.disabled = True;
    }
    control("status").textContent = "Bundlr has stopped. You can close this tab.";
}

async def keep_alive {
    try {
        await fetch("/heartbeat", {"method": "POST", "headers": auth(True)});
    } except Exception {}
}

def page_closed(event: any) {
    fetch("/close", {"method": "POST", "headers": auth(True), "keepalive": True});
}

with entry {
    control("target-" + config.target).checked = True;
    control("subtitle").textContent = "Package a Python application. Version "
        + config.version;
    control("form").addEventListener("submit", submit);
    control("cancel").addEventListener("click", cancel);
    control("quit").addEventListener("click", quit);
    window.addEventListener("pagehide", page_closed);
}

glob heartbeat: any = setInterval(keep_alive, 30000);
