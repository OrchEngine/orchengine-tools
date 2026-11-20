(function () {
    "use strict";

    const data = window.dependencyGraphData;
    const host = document.querySelector("[data-dependency-graph]");
    if (!data || !host) return;

    const NS = "http://www.w3.org/2000/svg";
    const ROOT = 0;
    const groups = new Map();
    const files = new Map();
    const externals = new Map();
    const initialFiles = new Map();
    const initialExternals = new Map();
    const collapsed = new Set();

    let svg = null;
    let layers = null;
    let view = { x: 0, y: 0, w: 1200, h: 800 };
    let drag = null;
    let panning = null;
    let renderQueued = false;

    data.groups.forEach(function (group) {
        const entry = Object.assign({}, group, { children: [], directFiles: [] });
        groups.set(group.id, entry);
    });
    data.groups.forEach(function (group) {
        if (group.parent === null || group.parent === undefined) return;
        const parent = groups.get(group.parent);
        if (parent) parent.children.push(groups.get(group.id));
    });
    data.nodes.forEach(function (node) {
        const entry = Object.assign({}, node);
        files.set(node.id, entry);
        const group = groups.get(node.group);
        if (group) group.directFiles.push(entry);
        initialFiles.set(node.id, { x: node.x, y: node.y });
    });
    data.externals.forEach(function (node) {
        const entry = Object.assign({}, node);
        externals.set(node.id, entry);
        initialExternals.set(node.id, { x: node.x, y: node.y });
    });

    function element(name, attrs) {
        const node = document.createElementNS(NS, name);
        if (attrs) {
            Object.keys(attrs).forEach(function (key) { node.setAttribute(key, attrs[key]); });
        }
        return node;
    }

    function text(content, attrs) {
        const node = element("text", attrs);
        node.textContent = content;
        return node;
    }

    function title(content) {
        const node = element("title");
        node.textContent = content;
        return node;
    }

    function groupOf(file) {
        return groups.get(file.group);
    }

    function ancestors(group) {
        const chain = [];
        let current = group;
        while (current) {
            chain.push(current);
            current = current.parent === null || current.parent === undefined ? null : groups.get(current.parent);
        }
        return chain;
    }

    function hiddenByAncestor(group) {
        let current = group.parent === null || group.parent === undefined ? null : groups.get(group.parent);
        while (current) {
            if (collapsed.has(current.id)) return true;
            current = current.parent === null || current.parent === undefined ? null : groups.get(current.parent);
        }
        return false;
    }

    function collapsedAncestor(group) {
        const chain = ancestors(group);
        let chosen = null;
        chain.forEach(function (entry) {
            if (collapsed.has(entry.id)) chosen = entry.id;
        });
        return chosen;
    }

    function visibleFile(file) {
        const group = groupOf(file);
        return !group || collapsedAncestor(group) === null;
    }

    function groupVisible(group) {
        return group.id !== ROOT && group.fileCount > 0 && !hiddenByAncestor(group);
    }

    function expandedGroups() {
        const out = [];
        groups.forEach(function (group) {
            if (groupVisible(group) && !collapsed.has(group.id)) out.push(group);
        });
        return out;
    }

    function collapsedGroups() {
        const out = [];
        groups.forEach(function (group) {
            if (groupVisible(group) && collapsed.has(group.id)) out.push(group);
        });
        return out;
    }

    function allFiles(group, out) {
        group.directFiles.forEach(function (file) { out.push(file); });
        group.children.forEach(function (child) { allFiles(child, out); });
        return out;
    }

    function groupFiles(group) {
        return allFiles(group, []);
    }

    function updateBounds() {
        const ordered = Array.from(groups.values()).sort(function (a, b) { return b.id - a.id; });
        ordered.forEach(function (group) {
            if (group.id === ROOT) return;
            let minX = Infinity;
            let minY = Infinity;
            let maxX = -Infinity;
            let maxY = -Infinity;
            function add(box) {
                if (!box || box.w <= 0 || box.h <= 0) return;
                minX = Math.min(minX, box.x);
                minY = Math.min(minY, box.y);
                maxX = Math.max(maxX, box.x + box.w);
                maxY = Math.max(maxY, box.y + box.h);
            }
            group.directFiles.forEach(add);
            group.children.forEach(function (child) {
                if (child.bounds) add(child.bounds);
            });
            if (minX === Infinity) {
                group.bounds = null;
                return;
            }
            const pad = 14;
            group.bounds = {
                x: minX - pad,
                y: minY - 38,
                w: maxX - minX + pad * 2,
                h: maxY - minY + 38 + pad
            };
        });
    }

    function summaryBox(group) {
        if (!group.bounds) return null;
        const w = Math.max(150, group.name.length * 7 + 54);
        const h = 50;
        return {
            x: group.bounds.x + (group.bounds.w - w) / 2,
            y: group.bounds.y + (group.bounds.h - h) / 2,
            w: w,
            h: h
        };
    }

    function fileBox(file) {
        return { x: file.x, y: file.y, w: file.w, h: file.h };
    }

    function externalBox(node) {
        return { x: node.x, y: node.y, w: node.w, h: node.h };
    }

    function endpoint(file) {
        const group = groupOf(file);
        if (!group) return "f:" + file.id;
        const id = collapsedAncestor(group);
        return id === null ? "f:" + file.id : "g:" + id;
    }

    function endpointBox(key) {
        if (key.indexOf("f:") === 0) {
            const file = files.get(Number(key.slice(2)));
            return file ? fileBox(file) : null;
        }
        if (key.indexOf("g:") === 0) {
            const group = groups.get(Number(key.slice(2)));
            return group ? summaryBox(group) : null;
        }
        const node = externals.get(Number(key.slice(2)));
        return node ? externalBox(node) : null;
    }

    function addEdge(map, from, to, cycle, generated, external) {
        if (!from || !to || from === to) return;
        const key = from + "|" + to;
        let edge = map.get(key);
        if (!edge) {
            edge = { from: from, to: to, count: 0, cycle: false, generated: true, external: Boolean(external) };
            map.set(key, edge);
        }
        edge.count += 1;
        if (cycle) edge.cycle = true;
        if (!generated) edge.generated = false;
    }

    function aggregateEdges() {
        const map = new Map();
        data.edges.forEach(function (edge) {
            const from = files.get(edge.from);
            const to = files.get(edge.to);
            if (!from || !to) return;
            addEdge(map, endpoint(from), endpoint(to), edge.cycle, edge.generated, false);
        });
        data.externalEdges.forEach(function (edge) {
            const from = files.get(edge.from);
            if (!from) return;
            addEdge(map, endpoint(from), "x:" + edge.to, false, false, true);
        });
        return Array.from(map.values());
    }

    function contentBounds() {
        let minX = Infinity;
        let minY = Infinity;
        let maxX = -Infinity;
        let maxY = -Infinity;
        function add(box) {
            if (!box || box.w <= 0 || box.h <= 0) return;
            minX = Math.min(minX, box.x);
            minY = Math.min(minY, box.y);
            maxX = Math.max(maxX, box.x + box.w);
            maxY = Math.max(maxY, box.y + box.h);
        }
        files.forEach(function (file) { if (visibleFile(file)) add(fileBox(file)); });
        collapsedGroups().forEach(function (group) { add(summaryBox(group)); });
        expandedGroups().forEach(function (group) { add(group.bounds); });
        externals.forEach(function (node) { add(externalBox(node)); });
        if (minX === Infinity) return { x: 0, y: 0, w: 1000, h: 700 };
        return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
    }

    function applyView() {
        if (!svg) return;
        svg.setAttribute("viewBox", view.x + " " + view.y + " " + view.w + " " + view.h);
    }

    function containerAspect() {
        const rect = host.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) return rect.width / rect.height;
        return 1.5;
    }

    function fitWidth() {
        const box = contentBounds();
        const pad = 60;
        const aspect = containerAspect();
        view = {
            x: box.x - pad,
            y: box.y - pad,
            w: Math.max(120, box.w + pad * 2),
            h: Math.max(120, box.w + pad * 2) / aspect
        };
        applyView();
    }

    function fitAll() {
        const box = contentBounds();
        const rect = host.getBoundingClientRect();
        const pad = 60;
        const cw = rect.width > 0 ? rect.width : 1200;
        const ch = rect.height > 0 ? rect.height : 800;
        const scale = Math.min(cw / Math.max(1, box.w + pad * 2), ch / Math.max(1, box.h + pad * 2));
        view = {
            x: box.x + box.w / 2 - cw / scale / 2,
            y: box.y + box.h / 2 - ch / scale / 2,
            w: cw / scale,
            h: ch / scale
        };
        applyView();
    }

    function zoomAt(px, py, factor) {
        const minW = 40;
        const maxW = 40000;
        const w = Math.max(minW, Math.min(maxW, view.w * factor));
        const k = w / view.w;
        view.x = px - (px - view.x) * k;
        view.y = py - (py - view.y) * k;
        view.w = w;
        view.h *= k;
        applyView();
    }

    function clientPoint(event) {
        const rect = host.getBoundingClientRect();
        const scale = Math.min(rect.width / view.w, rect.height / view.h) || 1;
        const ox = (rect.width - view.w * scale) / 2;
        const oy = (rect.height - view.h * scale) / 2;
        return {
            x: view.x + (event.clientX - rect.left - ox) / scale,
            y: view.y + (event.clientY - rect.top - oy) / scale
        };
    }

    function edgePoint(box, toward) {
        const cx = box.x + box.w / 2;
        const cy = box.y + box.h / 2;
        const dx = toward.x - cx;
        const dy = toward.y - cy;
        if (dx === 0 && dy === 0) return { x: cx, y: cy };
        const sx = dx === 0 ? Infinity : (box.w / 2) / Math.abs(dx);
        const sy = dy === 0 ? Infinity : (box.h / 2) / Math.abs(dy);
        const s = Math.min(sx, sy);
        return { x: cx + dx * s, y: cy + dy * s };
    }

    function edgePath(fromBox, toBox) {
        const a = edgePoint(fromBox, { x: toBox.x + toBox.w / 2, y: toBox.y + toBox.h / 2 });
        const b = edgePoint(toBox, { x: fromBox.x + fromBox.w / 2, y: fromBox.y + fromBox.h / 2 });
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        let c1;
        let c2;
        if (Math.abs(dx) >= Math.abs(dy)) {
            c1 = { x: a.x + dx * 0.42, y: a.y };
            c2 = { x: b.x - dx * 0.42, y: b.y };
        } else {
            c1 = { x: a.x, y: a.y + dy * 0.42 };
            c2 = { x: b.x, y: b.y - dy * 0.42 };
        }
        return "M" + a.x + "," + a.y + " C" + c1.x + "," + c1.y + " " + c2.x + "," + c2.y + " " + b.x + "," + b.y;
    }

    function marker(kind) {
        return "url(#dg-arrow-" + kind + ")";
    }

    function installDefs() {
        const defs = element("defs");
        const colors = {
            normal: "#5b6b7c",
            cycle: "#d93025",
            generated: "#8c959f",
            external: "#e37400"
        };
        Object.keys(colors).forEach(function (kind) {
            const markerNode = element("marker", {
                id: "dg-arrow-" + kind,
                viewBox: "0 0 10 10",
                refX: "9",
                refY: "5",
                markerWidth: "7",
                markerHeight: "7",
                orient: "auto-start-reverse"
            });
            const path = element("path", { d: "M0,0 L10,5 L0,10 z", fill: colors[kind] });
            markerNode.appendChild(path);
            defs.appendChild(markerNode);
        });
        svg.appendChild(defs);
    }

    function ensureSvg() {
        if (svg) return;
        svg = element("svg", { preserveAspectRatio: "xMidYMid meet" });
        installDefs();
        layers = {
            backgrounds: element("g"),
            edges: element("g"),
            nodes: element("g"),
            headers: element("g")
        };
        svg.appendChild(layers.backgrounds);
        svg.appendChild(layers.edges);
        svg.appendChild(layers.nodes);
        svg.appendChild(layers.headers);
        host.appendChild(svg);
        svg.addEventListener("wheel", onWheel, { passive: false });
        svg.addEventListener("pointerdown", onPointerDown);
        svg.addEventListener("pointermove", onPointerMove);
        svg.addEventListener("pointerup", onPointerUp);
        svg.addEventListener("pointercancel", onPointerUp);
        svg.addEventListener("keydown", onKeyDown);
    }

    function groupStyle(group) {
        if (group.cycle) return { fill: "#fffafa", stroke: "#d93025", dash: null, width: 1.6, text: "#a52714" };
        if (group.generated) return { fill: "#f6f8fa", stroke: "#8c959f", dash: "5 4", width: 1.2, text: "#57606a" };
        return { fill: "#fcfaff", stroke: "#d8c2f5", dash: null, width: 1.2, text: "#5b3a8f" };
    }

    function renderBackgrounds() {
        expandedGroups().forEach(function (group) {
            if (!group.bounds) return;
            const style = groupStyle(group);
            const rect = element("rect", {
                x: group.bounds.x,
                y: group.bounds.y,
                width: group.bounds.w,
                height: group.bounds.h,
                rx: 10,
                fill: style.fill,
                "fill-opacity": "0.55",
                stroke: style.stroke,
                "stroke-width": style.width
            });
            if (style.dash) rect.setAttribute("stroke-dasharray", style.dash);
            layers.backgrounds.appendChild(rect);
        });
    }

    function renderEdges() {
        aggregateEdges().forEach(function (edge) {
            const fromBox = endpointBox(edge.from);
            const toBox = endpointBox(edge.to);
            if (!fromBox || !toBox) return;
            let kind = "normal";
            let dash = null;
            if (edge.external) {
                kind = "external";
                dash = "5 4";
            } else if (edge.cycle) {
                kind = "cycle";
            } else if (edge.generated) {
                kind = "generated";
                dash = "4 3";
            }
            const path = element("path", {
                d: edgePath(fromBox, toBox),
                fill: "none",
                stroke: kind === "normal" ? "#5b6b7c" : kind === "cycle" ? "#d93025" : kind === "generated" ? "#8c959f" : "#e37400",
                "stroke-width": kind === "cycle" ? "1.8" : "1.2",
                "stroke-opacity": "0.82",
                "marker-end": marker(kind),
                class: "graph-edge"
            });
            if (dash) path.setAttribute("stroke-dasharray", dash);
            path.appendChild(title(edge.count + (edge.count === 1 ? " import" : " imports")));
            layers.edges.appendChild(path);
            if (edge.count > 1) {
                const a = edgePoint(fromBox, { x: toBox.x + toBox.w / 2, y: toBox.y + toBox.h / 2 });
                const b = edgePoint(toBox, { x: fromBox.x + fromBox.w / 2, y: fromBox.y + fromBox.h / 2 });
                const label = text(String(edge.count), {
                    x: (a.x + b.x) / 2,
                    y: (a.y + b.y) / 2 - 4,
                    "text-anchor": "middle",
                    "font-size": "9",
                    fill: "#57606a",
                    stroke: "#fff",
                    "stroke-width": "3",
                    "paint-order": "stroke"
                });
                layers.edges.appendChild(label);
            }
        });
    }

    function renderFile(file) {
        if (!visibleFile(file)) return;
        const node = element("g", {
            class: "graph-node graph-file",
            "data-drag-kind": "file",
            "data-drag-id": String(file.id)
        });
        const rect = element("rect", {
            x: file.x,
            y: file.y,
            width: file.w,
            height: file.h,
            rx: 6,
            fill: file.generated ? "#f6f8fa" : file.cycle ? "#fbe9e7" : "#f3e8fd",
            stroke: file.generated ? "#8c959f" : file.cycle ? "#d93025" : "#8250df",
            "stroke-width": file.cycle ? "1.6" : "1"
        });
        if (file.generated) rect.setAttribute("stroke-dasharray", "4 3");
        node.appendChild(rect);
        node.appendChild(text(file.label, {
            x: file.x + file.w / 2,
            y: file.y + file.h / 2 + 1,
            "text-anchor": "middle",
            "dominant-baseline": "middle",
            "font-size": "10",
            fill: "#1f2328"
        }));
        node.appendChild(title(file.path + "\n" + file.functions + " functions · " + file.debt + " min debt"));
        layers.nodes.appendChild(node);
    }

    function renderGroupHeader(group) {
        if (!group.bounds || group.id === ROOT) return;
        const style = groupStyle(group);
        const header = element("g", {
            class: "graph-header",
            "data-drag-kind": "group",
            "data-drag-id": String(group.id),
            tabindex: "0",
            role: "button"
        });
        const hit = element("rect", {
            x: group.bounds.x + 6,
            y: group.bounds.y + 4,
            width: group.bounds.w - 12,
            height: 32,
            fill: "transparent"
        });
        header.appendChild(hit);
        header.appendChild(text(group.name, {
            x: group.bounds.x + 14,
            y: group.bounds.y + 18,
            "font-size": "11.5",
            "font-weight": "700",
            fill: style.text
        }));
        header.appendChild(text(group.kind + " · " + group.fileCount + (group.fileCount === 1 ? " file" : " files"), {
            x: group.bounds.x + 14,
            y: group.bounds.y + 31,
            "font-size": "9",
            fill: "#6a737d"
        }));
        header.appendChild(text("−", {
            x: group.bounds.x + group.bounds.w - 18,
            y: group.bounds.y + 20,
            "text-anchor": "middle",
            "font-size": "15",
            fill: style.text
        }));
        header.appendChild(title("Collapse " + group.name));
        layers.headers.appendChild(header);
    }

    function renderCollapsed(group) {
        const box = summaryBox(group);
        if (!box) return;
        const style = groupStyle(group);
        const node = element("g", {
            class: "graph-node graph-group",
            "data-drag-kind": "group",
            "data-drag-id": String(group.id),
            tabindex: "0",
            role: "button"
        });
        const rect = element("rect", {
            x: box.x,
            y: box.y,
            width: box.w,
            height: box.h,
            rx: 8,
            fill: style.fill,
            stroke: style.stroke,
            "stroke-width": style.width
        });
        if (style.dash) rect.setAttribute("stroke-dasharray", style.dash);
        node.appendChild(rect);
        node.appendChild(text(group.name, {
            x: box.x + box.w / 2,
            y: box.y + 19,
            "text-anchor": "middle",
            "font-size": "11",
            "font-weight": "700",
            fill: style.text
        }));
        node.appendChild(text(group.fileCount + (group.fileCount === 1 ? " file" : " files") + " · " + group.kind, {
            x: box.x + box.w / 2,
            y: box.y + 35,
            "text-anchor": "middle",
            "font-size": "9",
            fill: "#6a737d"
        }));
        node.appendChild(title("Expand " + group.name));
        layers.nodes.appendChild(node);
    }

    function renderExternal(node) {
        const group = element("g", {
            class: "graph-node graph-external",
            "data-drag-kind": "external",
            "data-drag-id": String(node.id)
        });
        group.appendChild(element("rect", {
            x: node.x,
            y: node.y,
            width: node.w,
            height: node.h,
            rx: 5,
            fill: "#fff3cd",
            stroke: "#e37400",
            "stroke-width": "1",
            "stroke-dasharray": "4 3"
        }));
        group.appendChild(text(node.label, {
            x: node.x + node.w / 2,
            y: node.y + node.h / 2 + 1,
            "text-anchor": "middle",
            "dominant-baseline": "middle",
            "font-size": "9.5",
            fill: "#5c3a00"
        }));
        group.appendChild(title("Unresolved module import: " + node.label));
        layers.nodes.appendChild(group);
    }

    function render() {
        ensureSvg();
        updateBounds();
        layers.backgrounds.replaceChildren();
        layers.edges.replaceChildren();
        layers.nodes.replaceChildren();
        layers.headers.replaceChildren();
        renderBackgrounds();
        renderEdges();
        files.forEach(renderFile);
        collapsedGroups().forEach(renderCollapsed);
        externals.forEach(renderExternal);
        expandedGroups().forEach(renderGroupHeader);
        applyView();
    }

    function scheduleRender() {
        if (renderQueued) return;
        renderQueued = true;
        requestAnimationFrame(function () {
            renderQueued = false;
            render();
        });
    }

    function toggleGroup(id) {
        if (collapsed.has(id)) {
            collapsed.delete(id);
        } else {
            collapsed.add(id);
        }
        render();
    }

    function allGroups() {
        const out = [];
        groups.forEach(function (group) {
            if (group.id !== ROOT && group.fileCount > 0) out.push(group);
        });
        return out;
    }

    function resetLayout() {
        files.forEach(function (file) {
            const start = initialFiles.get(file.id);
            file.x = start.x;
            file.y = start.y;
        });
        externals.forEach(function (node) {
            const start = initialExternals.get(node.id);
            node.x = start.x;
            node.y = start.y;
        });
        collapsed.clear();
        render();
        fitWidth();
    }

    function startDrag(target, event) {
        const kind = target.getAttribute("data-drag-kind");
        const id = Number(target.getAttribute("data-drag-id"));
        const point = clientPoint(event);
        const entry = { kind: kind, id: id, sx: point.x, sy: point.y, moved: false, files: [], externals: [] };
        if (kind === "file") {
            const file = files.get(id);
            if (file) entry.files.push({ node: file, x: file.x, y: file.y });
        } else if (kind === "external") {
            const node = externals.get(id);
            if (node) entry.externals.push({ node: node, x: node.x, y: node.y });
        } else if (kind === "group") {
            const group = groups.get(id);
            if (group) groupFiles(group).forEach(function (file) { entry.files.push({ node: file, x: file.x, y: file.y }); });
        }
        return entry;
    }

    function onPointerDown(event) {
        if (event.button !== 0) return;
        const target = event.target.closest("[data-drag-kind]");
        if (target) {
            event.preventDefault();
            drag = startDrag(target, event);
            svg.setPointerCapture(event.pointerId);
            return;
        }
        panning = { sx: event.clientX, sy: event.clientY, x: view.x, y: view.y };
        event.preventDefault();
        svg.setPointerCapture(event.pointerId);
    }

    function onPointerMove(event) {
        if (drag) {
            const point = clientPoint(event);
            const dx = point.x - drag.sx;
            const dy = point.y - drag.sy;
            if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 3) return;
            drag.moved = true;
            host.classList.add("dragging");
            drag.files.forEach(function (entry) {
                entry.node.x = entry.x + dx;
                entry.node.y = entry.y + dy;
            });
            drag.externals.forEach(function (entry) {
                entry.node.x = entry.x + dx;
                entry.node.y = entry.y + dy;
            });
            scheduleRender();
            return;
        }
        if (!panning) return;
        const rect = host.getBoundingClientRect();
        const scale = Math.min(rect.width / view.w, rect.height / view.h) || 1;
        view.x = panning.x - (event.clientX - panning.sx) / scale;
        view.y = panning.y - (event.clientY - panning.sy) / scale;
        applyView();
    }

    function onPointerUp(event) {
        if (drag) {
            if (!drag.moved && drag.kind === "group") toggleGroup(drag.id);
            drag = null;
        }
        panning = null;
        host.classList.remove("dragging");
        try { svg.releasePointerCapture(event.pointerId); } catch (_) {}
    }

    function onKeyDown(event) {
        if (event.key !== "Enter" && event.key !== " ") return;
        const target = event.target.closest("[data-drag-kind='group']");
        if (!target) return;
        event.preventDefault();
        toggleGroup(Number(target.getAttribute("data-drag-id")));
    }

    function onWheel(event) {
        event.preventDefault();
        const point = clientPoint(event);
        zoomAt(point.x, point.y, event.deltaY < 0 ? 0.82 : 1.22);
    }

    function command(action) {
        if (action === "zoom-in" || action === "zoom-out") {
            const cx = view.x + view.w / 2;
            const cy = view.y + view.h / 2;
            zoomAt(cx, cy, action === "zoom-in" ? 0.72 : 1.38);
        } else if (action === "fit") {
            fitAll();
        } else if (action === "reset") {
            resetLayout();
        } else if (action === "collapse") {
            allGroups().forEach(function (group) { collapsed.add(group.id); });
            render();
            fitAll();
        } else if (action === "expand") {
            collapsed.clear();
            render();
            fitWidth();
        }
    }

    const shell = host.parentElement;
    if (shell) {
        shell.querySelectorAll("[data-graph-command]").forEach(function (button) {
            button.addEventListener("click", function () {
                command(button.getAttribute("data-graph-command"));
            });
        });
    }

    render();
    fitWidth();
})();
