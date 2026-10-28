(() => {
    "use strict";

    const base = location.pathname.replace(/\/+$/, "");
    const apiBase = `${base}/api`;
    const statusEl = document.getElementById("status");
    const refreshButton = document.getElementById("refresh");
    const summaryTitle = document.getElementById("summary-title");
    const summaryDetail = document.getElementById("summary-detail");
    const fileCount = document.getElementById("file-count");
    const filesEl = document.getElementById("files");
    const emptyEl = document.getElementById("empty");
    const template = document.getElementById("file-template");
    const downloadAll = document.getElementById("download-all");
    downloadAll.href = `${base}/api/zip`;
    downloadAll.addEventListener("click", (event) => {
        if (totalBytes > BLOB_DOWNLOAD_LIMIT) return;
        event.preventDefault();
        downloadWithFallback(downloadAll.href, "Macdro.zip");
    });

    let lastSignature = "";
    let polling = null;
    let eventSource = null;
    let totalBytes = 0;
    let downloadActive = false;

    const BLOB_DOWNLOAD_LIMIT = 512 * 1024 * 1024;

    const downloadViaBlob = async (url, name) => {
        downloadActive = true;
        try {
            setStatus("online", `Downloading ${name}…`);
            const response = await fetch(url);
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const total = Number(response.headers.get("content-length")) || 0;
            const reader = response.body.getReader();
            const chunks = [];
            let received = 0;
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                chunks.push(value);
                received += value.length;
                if (total > 0) {
                    const percent = Math.min(100, Math.round((received / total) * 100));
                    setStatus("online", `Downloading ${name} · ${percent}%`);
                }
            }
            const blob = new Blob(chunks, {
                type: response.headers.get("content-type") || "application/octet-stream"
            });
            const objectUrl = URL.createObjectURL(blob);
            const anchor = document.createElement("a");
            anchor.href = objectUrl;
            anchor.download = name;
            document.body.appendChild(anchor);
            anchor.click();
            anchor.remove();
            setTimeout(() => URL.revokeObjectURL(objectUrl), 60000);
            setStatus("online", `Saved ${name}`);
        } finally {
            downloadActive = false;
        }
    };

    const downloadWithFallback = (url, name) => {
        downloadViaBlob(url, name).catch((error) => {
            setStatus("offline", `Download failed: ${error && error.message ? error.message : error}`);
        });
    };

    const formatBytes = (value) => {
        if (!Number.isFinite(value) || value < 0) return "—";
        if (value === 0) return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB", "PB"];
        const index = Math.min(Math.floor(Math.log(value) / Math.log(1000)), units.length - 1);
        const number = value / Math.pow(1000, index);
        return `${number >= 10 || index === 0 ? number.toFixed(0) : number.toFixed(1)} ${units[index]}`;
    };

    const setStatus = (state, text) => {
        statusEl.className = `status ${state}`;
        statusEl.innerHTML = "";
        const dot = document.createElement("span");
        dot.className = "dot";
        statusEl.append(dot, document.createTextNode(text));
    };

    const signatureFor = (files) => files.map((file) => `${file.id}:${file.size}`).join("|");

    const makeRow = (file) => {
        const row = template.content.firstElementChild.cloneNode(true);
        row.querySelector(".file-name").textContent = file.name;
        const path = file.path && file.path !== file.name ? file.path : "";
        const details = [formatBytes(file.size), path].filter(Boolean).join(" · ");
        row.querySelector(".file-sub").textContent = details;
        const link = row.querySelector(".download");
        link.href = `${base}/f/${file.id}`;
        link.setAttribute("download", file.name);
        link.addEventListener("click", (event) => {
            if (file.size > BLOB_DOWNLOAD_LIMIT) return;
            event.preventDefault();
            downloadWithFallback(link.href, file.name);
        });
        return row;
    };

    const render = (session) => {
        const files = Array.isArray(session.files) ? session.files : [];
        const signature = signatureFor(files);
        totalBytes = session.totalBytes || 0;
        if (!downloadActive) setStatus("online", "Connected to Mac");

        fileCount.textContent = String(files.length);
        downloadAll.classList.toggle("hidden", files.length === 0);
        if (files.length === 0) {
            summaryTitle.textContent = "Waiting for files";
            summaryDetail.textContent = "Drop files on the Macdro icon on your Mac.";
            emptyEl.classList.remove("hidden");
        } else {
            summaryTitle.textContent = files.length === 1 ? "1 file ready" : `${files.length} files ready`;
            summaryDetail.textContent = `${formatBytes(session.totalBytes || 0)} total · Tap download to save`;
            emptyEl.classList.add("hidden");
        }

        if (signature === lastSignature) return;
        lastSignature = signature;

        filesEl.innerHTML = "";
        for (const file of files) {
            filesEl.appendChild(makeRow(file));
        }
    };

    const request = async (options = {}) => {
        const response = await fetch(`${apiBase}/session`, {
            cache: "no-store",
            ...options
        });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        return response.json();
    };

    const startPolling = () => {
        if (!polling) {
            polling = window.setInterval(() => refresh(false), 1500);
        }
    };

    const startEventStream = () => {
        if (!window.EventSource) return false;
        eventSource = new EventSource(`${apiBase}/events`);
        eventSource.onmessage = (event) => {
            try {
                render(JSON.parse(event.data));
            } catch (_) {}
        };
        eventSource.onerror = () => {
            if (eventSource) {
                eventSource.close();
                eventSource = null;
            }
            startPolling();
        };
        return true;
    };

    const refresh = async (showSpinner = false) => {
        if (showSpinner) refreshButton.classList.add("loading");
        try {
            const session = await request();
            render(session);
            if (!polling && !eventSource) {
                if (!startEventStream()) startPolling();
            }
        } catch (error) {
            const status = Number(String(error && error.message || "").replace("HTTP ", ""));
            setStatus("offline", status === 401 || status === 404 ? "Session ended" : "Connection lost");
            summaryTitle.textContent = status === 401 || status === 404 ? "Session ended" : "Connection lost";
            summaryDetail.textContent = status === 401 || status === 404
                ? "Ask your Mac to share again, then rescan the QR code."
                : "Check that this device is still on the same Wi-Fi network.";
            emptyEl.classList.add("hidden");
            if (polling) {
                window.clearInterval(polling);
                polling = null;
            }
            if (eventSource) {
                eventSource.close();
                eventSource = null;
            }
        } finally {
            if (showSpinner) refreshButton.classList.remove("loading");
        }
    };
    const uploadPanel = document.getElementById("upload-panel");
    const uploadInput = document.getElementById("upload-input");
    const folderInput = document.getElementById("folder-input");
    const uploadsEl = document.getElementById("uploads");
    const clipboardCopy = document.getElementById("clipboard-copy");
    const clipboardSend = document.getElementById("clipboard-send");
    const clipboardStatus = document.getElementById("clipboard-status");
    const uploadQueue = [];
    let activeUploads = 0;
    let refreshTimer = null;

    const setClipboardStatus = (text, isError = false) => {
        clipboardStatus.textContent = text;
        clipboardStatus.classList.toggle("error", isError);
    };

    const writeClipboard = async (text) => {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            await navigator.clipboard.writeText(text);
            return;
        }
        const input = document.createElement("textarea");
        input.value = text;
        input.style.position = "fixed";
        input.style.opacity = "0";
        document.body.appendChild(input);
        input.select();
        const copied = document.execCommand("copy");
        input.remove();
        if (!copied) throw new Error("Clipboard unavailable");
    };

    clipboardCopy.addEventListener("click", async () => {
        setClipboardStatus("Reading Mac clipboard…");
        try {
            const response = await fetch(`${apiBase}/clipboard`, { cache: "no-store" });
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            await writeClipboard(await response.text());
            setClipboardStatus("Copied from Mac");
        } catch (_) {
            setClipboardStatus("Could not read the Mac clipboard", true);
        }
    });

    clipboardSend.addEventListener("click", async () => {
        let text = null;
        try {
            if (navigator.clipboard && navigator.clipboard.readText) {
                text = await navigator.clipboard.readText();
            } else {
                text = window.prompt("Text to send to your Mac:");
            }
        } catch (_) {
            text = window.prompt("Text to send to your Mac:");
        }
        if (text === null) return;
        setClipboardStatus("Sending clipboard…");
        try {
            const response = await fetch(`${apiBase}/clipboard`, {
                method: "PUT",
                headers: { "Content-Type": "text/plain; charset=utf-8" },
                body: text
            });
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            setClipboardStatus("Sent to Mac");
        } catch (_) {
            setClipboardStatus("Could not send clipboard", true);
        }
    });

    const uploadIcon = `
        <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 19V6m0 0-5 5m5-5 5 5M5 20h14"/>
        </svg>`;

    const makeUploadRow = (file, relativePath) => {
        const row = document.createElement("article");
        row.className = "upload-row";

        const icon = document.createElement("div");
        icon.className = "upload-row-icon";
        icon.innerHTML = uploadIcon;

        const meta = document.createElement("div");
        meta.className = "upload-row-meta";

        const name = document.createElement("p");
        name.className = "upload-row-name";
        name.textContent = relativePath || file.name;

        const progress = document.createElement("div");
        progress.className = "progress";
        const bar = document.createElement("span");
        progress.appendChild(bar);

        const sub = document.createElement("p");
        sub.className = "upload-row-sub";
        sub.textContent = "Waiting…";

        const actions = document.createElement("div");
        actions.className = "upload-row-actions";

        const cancel = document.createElement("button");
        cancel.type = "button";
        cancel.className = "upload-row-action";
        cancel.textContent = "Cancel";

        const retry = document.createElement("button");
        retry.type = "button";
        retry.className = "upload-row-action";
        retry.textContent = "Retry";
        retry.hidden = true;

        actions.append(cancel, retry);
        meta.append(name, progress, sub);
        row.append(icon, meta, actions);
        uploadsEl.prepend(row);

        return { row, bar, sub, name, cancel, retry };
    };

    const CHUNK_SIZE = 16 * 1024 * 1024;
    const MAX_PARALLEL_UPLOADS = 3;
    const MAX_RETRIES = 5;

    const makeUploadID = () => {
        if (window.crypto && typeof window.crypto.randomUUID === "function") {
            return window.crypto.randomUUID().replace(/-/g, "");
        }
        const bytes = new Uint8Array(16);
        if (window.crypto && typeof window.crypto.getRandomValues === "function") {
            window.crypto.getRandomValues(bytes);
        } else {
            for (let index = 0; index < bytes.length; index += 1) {
                bytes[index] = Math.floor(Math.random() * 256);
            }
        }
        return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    };

    const openUploadDatabase = () => new Promise((resolve) => {
        if (!window.indexedDB) {
            resolve(null);
            return;
        }
        const request = window.indexedDB.open("macdro-uploads", 1);
        request.onupgradeneeded = () => {
            if (!request.result.objectStoreNames.contains("resume")) {
                request.result.createObjectStore("resume", { keyPath: "key" });
            }
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => resolve(null);
    });

    const uploadDatabase = openUploadDatabase();
    const resumeKey = (file, relativePath) =>
        `${relativePath}\u0000${file.size}\u0000${file.lastModified}`;

    const readResume = async (key) => {
        const database = await uploadDatabase;
        if (!database) return null;
        return new Promise((resolve) => {
            try {
                const transaction = database.transaction("resume", "readonly");
                const request = transaction.objectStore("resume").get(key);
                request.onsuccess = () => resolve(request.result || null);
                request.onerror = () => resolve(null);
            } catch (_) {
                resolve(null);
            }
        });
    };

    const writeResume = async (key, uploadId, offset) => {
        const database = await uploadDatabase;
        if (!database) return;
        return new Promise((resolve) => {
            try {
                const transaction = database.transaction("resume", "readwrite");
                transaction.objectStore("resume").put({ key, uploadId, offset });
                transaction.oncomplete = () => resolve();
                transaction.onerror = () => resolve();
            } catch (_) {
                resolve();
            }
        });
    };

    const clearResume = async (key) => {
        const database = await uploadDatabase;
        if (!database) return;
        return new Promise((resolve) => {
            try {
                const transaction = database.transaction("resume", "readwrite");
                transaction.objectStore("resume").delete(key);
                transaction.oncomplete = () => resolve();
                transaction.onerror = () => resolve();
            } catch (_) {
                resolve();
            }
        });
    };

    const cancelEntry = (entry) => {
        entry.canceled = true;
        if (typeof entry.cancel === "function") entry.cancel();
        const { row, bar, sub, cancel, retry } = entry.row;
        cancel.hidden = true;
        retry.hidden = true;
        row.classList.remove("error", "success");
        row.classList.add("cancelled");
        bar.style.width = "0%";
        sub.textContent = "Cancelled";
    };

    const retryEntry = (entry) => {
        if (entry.retrying || entry.done) return;
        entry.retrying = true;
        entry.canceled = false;
        const { row, bar, sub, cancel, retry } = entry.row;
        retry.hidden = true;
        cancel.hidden = false;
        row.classList.remove("error", "cancelled", "success");
        bar.style.width = "0%";
        sub.textContent = "Waiting…";
        uploadQueue.push(entry);
        processUploads();
    };

    const uploadFile = async (entry) => {
        const file = entry.file;
        const relativePath = entry.path || file.name;
        const { row, bar, sub, name, cancel, retry } = entry.row;
        const key = resumeKey(file, relativePath);
        const savedResume = await readResume(key);
        const uploadId = savedResume && savedResume.uploadId
            ? savedResume.uploadId
            : makeUploadID();
        let offset = savedResume && Number.isFinite(savedResume.offset)
            ? Math.min(savedResume.offset, file.size)
            : 0;
        let retries = 0;
        let activeRequest = null;
        entry.retrying = false;
        entry.cancel = () => {
            entry.canceled = true;
            if (activeRequest) activeRequest.abort();
        };

        const setProgress = (loaded) => {
            const percent = file.size > 0 ? Math.min(100, (loaded / file.size) * 100) : 100;
            bar.style.width = `${percent}%`;
            sub.textContent = file.size > 0
                ? `${formatBytes(loaded)} of ${formatBytes(file.size)}`
                : "Saving…";
        };

        const fail = (message) => {
            row.classList.remove("cancelled");
            row.classList.add("error");
            bar.style.width = "0%";
            sub.textContent = message;
            cancel.hidden = true;
            retry.hidden = false;
            entry.retrying = false;
            activeRequest = null;
        };

        const uploadErrorMessage = (status) => {
            if (status === 413) return "File is larger than the Mac allows";
            if (status === 429) return "Too many uploads — try again shortly";
            if (status === 507) return "The Mac does not have enough free space";
            if (status === 401 || status === 404) return "Session ended — rescan the QR code";
            return `Upload failed (HTTP ${status})`;
        };

        const succeed = async (saved) => {
            entry.done = true;
            row.classList.add("success");
            bar.style.width = "100%";
            sub.textContent = saved && (saved.path || saved.name)
                ? `Saved as ${saved.path || saved.name}`
                : "Saved on Mac";
            if (saved && (saved.path || saved.name)) name.textContent = saved.path || saved.name;
            cancel.hidden = true;
            retry.hidden = true;
            await clearResume(key);
        };

        const sendChunk = () => new Promise((resolveChunk, rejectChunk) => {
            const start = offset;
            const end = Math.min(start + CHUNK_SIZE, file.size);
            const complete = end >= file.size;
            const params = new URLSearchParams({
                uploadId,
                name: file.name,
                offset: String(start),
                total: String(file.size)
            });
            if (relativePath !== file.name) params.set("path", relativePath);
            if (complete) params.set("complete", "1");

            const xhr = new XMLHttpRequest();
            activeRequest = xhr;
            xhr.open("PUT", `${apiBase}/upload?${params.toString()}`, true);
            xhr.setRequestHeader("Content-Type", "application/octet-stream");
            xhr.upload.onprogress = (event) => {
                if (event.lengthComputable) setProgress(start + event.loaded);
            };
            xhr.onload = () => {
                activeRequest = null;
                if (xhr.status === 409) {
                    const next = Number(xhr.getResponseHeader("X-Upload-Offset"));
                    if (Number.isFinite(next) && next >= 0 && next <= file.size) {
                        if (complete && next === file.size) {
                            resolveChunk({ done: true, payload: null });
                            return;
                        }
                        offset = next;
                        writeResume(key, uploadId, offset);
                        resolveChunk({ retry: true });
                        return;
                    }
                }
                if (xhr.status >= 200 && xhr.status < 300) {
                    let payload = null;
                    try { payload = JSON.parse(xhr.responseText); } catch (_) {}
                    if (payload && Number.isFinite(payload.offset)) {
                        offset = Math.min(payload.offset, file.size);
                    } else {
                        offset = end;
                    }
                    if (complete || (payload && payload.complete)) {
                        resolveChunk({ done: true, payload });
                    } else {
                        writeResume(key, uploadId, offset);
                        resolveChunk({ done: false });
                    }
                    return;
                }
                const error = new Error(`HTTP ${xhr.status}`);
                error.status = xhr.status;
                rejectChunk(error);
            };
            xhr.onerror = () => {
                activeRequest = null;
                rejectChunk(new Error("network"));
            };
            xhr.onabort = () => {
                activeRequest = null;
                rejectChunk(new Error("cancelled"));
            };

            setProgress(start);
            xhr.send(file.slice(start, end));
        });

        while (true) {
            if (entry.canceled) return;
            try {
                const result = await sendChunk();
                if (entry.canceled) return;
                if (result.retry) {
                    retries += 1;
                    if (retries > MAX_RETRIES) {
                        fail("Upload could not resume");
                        return;
                    }
                    continue;
                }
                if (result.done) {
                    await succeed(result.payload);
                    return;
                }
                retries = 0;
            } catch (error) {
                if (entry.canceled) return;
                retries += 1;
                if (retries > MAX_RETRIES || (error.status && error.status < 500 && error.status !== 408)) {
                    fail(uploadErrorMessage(error.status));
                    return;
                }
                sub.textContent = `Connection lost — retrying (${retries}/${MAX_RETRIES})…`;
                await new Promise((timer) => window.setTimeout(
                    timer,
                    Math.min(500 * (2 ** (retries - 1)), 8000)
                ));
            }
        }
    };

    const scheduleRefresh = () => {
        if (refreshTimer) window.clearTimeout(refreshTimer);
        refreshTimer = window.setTimeout(() => {
            refreshTimer = null;
            refresh(false);
        }, 250);
    };

    const processUploads = () => {
        while (activeUploads < MAX_PARALLEL_UPLOADS && uploadQueue.length > 0) {
            const entry = uploadQueue.shift();
            if (entry.canceled || entry.done) continue;
            activeUploads += 1;
            uploadFile(entry)
                .catch(() => {
                    const { row, sub, cancel, retry } = entry.row;
                    row.classList.add("error");
                    sub.textContent = "Upload failed";
                    cancel.hidden = true;
                    retry.hidden = false;
                })
                .finally(() => {
                    activeUploads -= 1;
                    processUploads();
                });
        }
        if (activeUploads === 0 && uploadQueue.length === 0) scheduleRefresh();
    };

    const enqueueUploads = (entries) => {
        for (const entry of entries) {
            if (entry.canceled || entry.done) continue;
            if (!entry.row) {
                const relativePath = entry.path || entry.file.name;
                entry.row = makeUploadRow(entry.file, relativePath);
                entry.row.cancel.addEventListener("click", () => cancelEntry(entry));
                entry.row.retry.addEventListener("click", () => retryEntry(entry));
            }
            uploadQueue.push(entry);
        }
        processUploads();
    };

    const fileEntries = (files) => Array.from(files).map((file) => ({
        file,
        path: file.webkitRelativePath || file.name
    }));

    const readAllDirectoryEntries = (reader) => new Promise((resolve, reject) => {
        const collected = [];
        const readBatch = () => {
            reader.readEntries((batch) => {
                if (!batch.length) {
                    resolve(collected);
                    return;
                }
                collected.push(...batch);
                readBatch();
            }, reject);
        };
        readBatch();
    });

    const walkEntry = async (entry, prefix) => {
        const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (entry.isFile) {
            const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
            return [{ file, path: relativePath }];
        }
        if (entry.isDirectory) {
            const children = await readAllDirectoryEntries(entry.createReader());
            const nested = [];
            for (const child of children) {
                nested.push(...await walkEntry(child, relativePath));
            }
            return nested;
        }
        return [];
    };

    const entriesFromDataTransfer = async (dataTransfer) => {
        const items = dataTransfer.items ? Array.from(dataTransfer.items) : [];
        const entries = items
            .filter((item) => item.kind === "file" && typeof item.webkitGetAsEntry === "function")
            .map((item) => item.webkitGetAsEntry())
            .filter(Boolean);

        if (entries.length > 0) {
            const collected = [];
            for (const entry of entries) {
                collected.push(...await walkEntry(entry, ""));
            }
            if (collected.length > 0) return collected;
        }
        return fileEntries(dataTransfer.files || []);
    };

    uploadInput.addEventListener("change", () => {
        if (uploadInput.files && uploadInput.files.length > 0) {
            enqueueUploads(fileEntries(uploadInput.files));
        }
        uploadInput.value = "";
    });

    folderInput.addEventListener("change", () => {
        if (folderInput.files && folderInput.files.length > 0) {
            enqueueUploads(fileEntries(folderInput.files));
        }
        folderInput.value = "";
    });

    uploadPanel.addEventListener("dragover", (event) => {
        event.preventDefault();
        uploadPanel.classList.add("dragging");
    });

    uploadPanel.addEventListener("dragleave", () => {
        uploadPanel.classList.remove("dragging");
    });

    uploadPanel.addEventListener("drop", async (event) => {
        event.preventDefault();
        uploadPanel.classList.remove("dragging");
        if (event.dataTransfer) {
            enqueueUploads(await entriesFromDataTransfer(event.dataTransfer));
        }
    });
    refreshButton.addEventListener("click", () => refresh(true));
    document.addEventListener("visibilitychange", () => {
        if (!document.hidden) refresh(false);
    });

    refresh(true);
})();
