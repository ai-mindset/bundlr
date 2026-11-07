"""Browser behavior authored in Jac; compiled to a static ES module for the native server."""
glob config: dict[str, str] = JSON.parse(
         (document.getElementById("config") as HTMLElement).textContent as str
     ) as dict[str, str],
     newline: str = chr(10),
     quitting: bool = False;

def control(id: str) -> HTMLElement {
    return document.getElementById(id) as HTMLElement;
}

def field(id: str) -> HTMLInputElement | HTMLSelectElement {
    return control(id) as HTMLInputElement | HTMLSelectElement;
}

def button(id: str) -> HTMLButtonElement {
    return control(id) as HTMLButtonElement;
}

def auth(page: bool = False) -> dict[str, str] {
    headers = {"content-type": "application/json", "x-bundlr-token": config["token"]};
    if page {
        headers["x-bundlr-page"] = config["pageId"];
    }
    return headers;
}

def output(stream: str, text: str) {
    span = document.createElement("span") as HTMLElement;
    if stream == "stderr" {
        span.className = "stderr";
    }
    span.textContent = text;
    # Jac 0.39's DOM declarations omit Element.append.
    (control("output") as any).append(span);
    control("output").scrollTop = control("output").scrollHeight;
}

async def submit(event: FormEvent) {
    event.preventDefault();
    if quitting {
        return;
    }
    control("output").textContent = "";
    control("status").textContent = "Packaging application...";
    button("package").disabled = True;
    button("cancel").disabled = False;
    try {
        targets: list[str] = [];
        for item in (
            document.querySelectorAll('input[name="target"]:checked') as Iterable[
                HTMLInputElement
            ]
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
                        "source": field("source").value,
                        "applicationName": field("applicationName").value,
                        "command": field("command").value,
                        "applicationKind": field("applicationKind").value,
                        "python": field("python").value,
                        "outputDirectory": field("outputDirectory").value,
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
                message = JSON.parse(line) as dict[str, str | list[dict[str, str]]];
                if message["type"] == "output" {
                    output(message["stream"] as str, message["text"] as str);
                }
                if message["type"] == "error" {
                    raise Exception(message["message"] as str);
                }
                if message["type"] == "done" {
                    complete = True;
                    names: list[str] = [];
                    for result in (message["results"] as list[dict[str, str]]) {
                        names.append(result["archivePath"]);
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
            button("package").disabled = False;
            button("cancel").disabled = True;
        }
    }
}

async def cancel(_event: MouseEvent) {
    control("status").textContent = "Cancelling...";
    await fetch("/cancel", {"method": "POST", "headers": auth()});
}

async def quit(_event: MouseEvent) {
    quitting = True;
    await fetch("/quit", {"method": "POST", "headers": auth()});
    clearInterval(heartbeat);
    for item in (
        document.querySelectorAll("button, input, select") as Iterable[
            HTMLButtonElement | HTMLInputElement | HTMLSelectElement
        ]
    ) {
        item.disabled = True;
    }
    control("status").textContent = "Bundlr has stopped. You can close this tab.";
}

async def keep_alive {
    try {
        await fetch("/heartbeat", {"method": "POST", "headers": auth(True)});
    } except Exception {}
}

def page_closed(_event: Event) {
    fetch("/close", {"method": "POST", "headers": auth(True), "keepalive": True});
}

with entry {
    (control("target-" + config["target"]) as HTMLInputElement).checked = True;
    control("subtitle").textContent = "Package a Python application. Version "
        + config["version"];
    control("form").addEventListener("submit", submit);
    control("cancel").addEventListener("click", cancel);
    control("quit").addEventListener("click", quit);
    window.addEventListener("pagehide", page_closed);
}

glob heartbeat: int = setInterval(keep_alive, 30000) as int;
