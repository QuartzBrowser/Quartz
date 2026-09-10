// Kept inline so SwiftPM executables and packaged apps use the same scripts.
// Real WebKit extraction coverage lives in QuartzReaderModeTests.
enum QuartzReaderMode {
    static let enterScript = #"""
(() => {
    if (window.__quartzReaderMode?.overlay?.isConnected) {
        return { ok: true, alreadyActive: true };
    }

    const cleanText = (value) => (value || "").replace(/\s+/g, " ").trim();
    const pageTitle = cleanText(
        document.querySelector("meta[property='og:title']")?.content ||
        document.querySelector("meta[name='twitter:title']")?.content ||
        document.querySelector("h1")?.innerText ||
        document.title ||
        location.hostname
    );
    const byline = cleanText(
        document.querySelector("meta[name='author']")?.content ||
        document.querySelector("[rel='author']")?.innerText ||
        document.querySelector(".byline, .author, [class*='byline'], [class*='author']")?.innerText ||
        ""
    );
    const site = cleanText(
        document.querySelector("meta[property='og:site_name']")?.content ||
        location.hostname.replace(/^www\./, "")
    );
    const isVisible = (element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== "none" &&
            style.visibility !== "hidden" &&
            rect.width > 0 &&
            rect.height > 0;
    };
    const textFor = (element) => cleanText(element.innerText || element.textContent || "");
    const signatureFor = (element) => `${element.id || ""} ${element.className || ""}`.toLowerCase();
    const scoreCandidate = (element) => {
        const text = textFor(element);
        const paragraphs = Array.from(element.querySelectorAll("p"));
        const paragraphTextLength = paragraphs.reduce((length, paragraph) => length + textFor(paragraph).length, 0);
        const linkTextLength = Array.from(element.querySelectorAll("a"))
            .reduce((length, link) => length + textFor(link).length, 0);
        const textLength = Math.max(text.length, paragraphTextLength);

        if (textLength < 500 || paragraphTextLength < 280) {
            return -Infinity;
        }

        const tagScore = {
            ARTICLE: 900,
            MAIN: 780,
            SECTION: 180,
            DIV: 80
        }[element.tagName] || 0;
        const signature = signatureFor(element);
        const positive = /(article|content|entry|feature|main|post|reader|story|text)/.test(signature) ? 420 : 0;
        const negative = /(ad|aside|banner|comment|footer|header|menu|modal|nav|promo|related|share|sidebar|sponsor|subscribe)/.test(signature) ? 760 : 0;
        const linkPenalty = (linkTextLength / Math.max(textLength, 1)) * 1050;
        const paragraphScore = paragraphs.length * 90;
        const headingScore = element.querySelectorAll("h1, h2, h3").length * 30;
        const mediaScore = Math.min(element.querySelectorAll("img, picture, figure").length, 4) * 25;

        return tagScore + positive + paragraphScore + headingScore + mediaScore + (textLength * 0.18) - negative - linkPenalty;
    };

    const candidates = Array.from(document.querySelectorAll("article, main, [role='main'], section, div"))
        .filter(isVisible);
    const best = candidates
        .map((element) => ({ element, score: scoreCandidate(element) }))
        .sort((left, right) => right.score - left.score)[0];
    const source = best?.score > 0 ? best.element : document.body;
    const clone = source.cloneNode(true);
    const junkSelector = [
        "script",
        "style",
        "noscript",
        "iframe",
        "nav",
        "footer",
        "header",
        "aside",
        "form",
        "button",
        "input",
        "textarea",
        "select",
        "svg",
        "canvas",
        "video",
        "audio",
        "[hidden]",
        "[aria-hidden='true']",
        "[role='banner']",
        "[role='contentinfo']",
        "[role='navigation']",
        "[class*='advert']",
        "[class*='comment']",
        "[class*='modal']",
        "[class*='newsletter']",
        "[class*='promo']",
        "[class*='related']",
        "[class*='share']",
        "[class*='sidebar']",
        "[class*='sponsor']",
        "[class*='subscribe']",
        "[id*='advert']",
        "[id*='comment']",
        "[id*='newsletter']",
        "[id*='promo']",
        "[id*='related']",
        "[id*='share']",
        "[id*='sidebar']",
        "[id*='subscribe']"
    ].join(",");

    clone.querySelectorAll(junkSelector).forEach((node) => node.remove());
    clone.querySelectorAll("a[href]").forEach((link) => {
        try {
            link.href = new URL(link.getAttribute("href"), document.baseURI).href;
        } catch {}
    });
    clone.querySelectorAll("img[src], source[src], picture source[src]").forEach((media) => {
        try {
            media.src = new URL(media.getAttribute("src"), document.baseURI).href;
        } catch {}
    });
    clone.querySelectorAll("*").forEach((node) => {
        for (const attribute of Array.from(node.attributes)) {
            const name = attribute.name.toLowerCase();
            const allowed = ["href", "src", "srcset", "alt", "title", "datetime", "cite", "colspan", "rowspan"];
            if (name.startsWith("on") || name === "style" || name === "id" || name === "class" || name === "srcdoc") {
                node.removeAttribute(attribute.name);
            } else if (!allowed.includes(name) && !name.startsWith("aria-")) {
                node.removeAttribute(attribute.name);
            }
        }
    });
    clone.querySelectorAll("p, li, blockquote, pre, h1, h2, h3, h4, h5, h6").forEach((node) => {
        if (!cleanText(node.textContent) && node.querySelector("img, picture, video, iframe") === null) {
            node.remove();
        }
    });

    const articleText = textFor(clone);
    if (articleText.length < 500) {
        return { ok: false, reason: "tooShort" };
    }

    const escapeHTML = (value) => String(value || "").replace(/[&<>"']/g, (character) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        "\"": "&quot;",
        "'": "&#39;"
    }[character]));
    const wordCount = articleText.split(/\s+/).filter(Boolean).length;
    const readingMinutes = Math.max(1, Math.round(wordCount / 235));
    const metaParts = [site, byline, `${readingMinutes} min read`].filter(Boolean);

    const overlay = document.createElement("div");
    overlay.id = "quartz-reading-mode";
    overlay.setAttribute("role", "main");
    const shadow = overlay.attachShadow({ mode: "open" });
    shadow.innerHTML = `
        <style>
            :host {
                all: initial;
                position: fixed;
                inset: 0;
                z-index: 2147483647;
                overflow: auto;
                background: #fafaf8;
                color: #202124;
                color-scheme: light;
                font-family: ui-serif, Georgia, Cambria, "Times New Roman", Times, serif;
                -webkit-font-smoothing: antialiased;
            }

            * {
                box-sizing: border-box;
            }

            .shell {
                min-height: 100%;
                padding: clamp(28px, 5vw, 72px) clamp(20px, 7vw, 96px);
            }

            article {
                width: min(100%, 760px);
                margin: 0 auto;
            }

            header {
                margin-bottom: 2.35rem;
                padding-bottom: 1.4rem;
                border-bottom: 1px solid rgba(32, 33, 36, 0.14);
            }

            .meta {
                margin-bottom: 0.9rem;
                color: #5f665f;
                font: 500 0.82rem/1.55 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                letter-spacing: 0;
            }

            h1 {
                margin: 0;
                color: #17191c;
                font-size: clamp(2rem, 4vw, 3.45rem);
                line-height: 1.06;
                font-weight: 720;
                letter-spacing: 0;
            }

            .content {
                font-size: 1.23rem;
                line-height: 1.75;
            }

            .content :is(h1, h2, h3, h4, h5, h6) {
                color: #1f2324;
                font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                letter-spacing: 0;
                line-height: 1.2;
                margin: 2.2em 0 0.7em;
            }

            .content h1 {
                font-size: 2rem;
            }

            .content h2 {
                font-size: 1.55rem;
            }

            .content h3 {
                font-size: 1.28rem;
            }

            .content p,
            .content ul,
            .content ol,
            .content blockquote,
            .content pre,
            .content table,
            .content figure {
                margin: 0 0 1.25em;
            }

            .content a {
                color: #0b6f6a;
                text-decoration-color: rgba(11, 111, 106, 0.35);
                text-decoration-thickness: 0.08em;
                text-underline-offset: 0.16em;
            }

            .content img,
            .content picture {
                display: block;
                max-width: 100%;
                height: auto;
                margin: 1.55rem auto;
                border-radius: 6px;
            }

            .content blockquote {
                padding-left: 1.1em;
                border-left: 3px solid rgba(11, 111, 106, 0.42);
                color: #49524f;
                font-style: italic;
            }

            .content pre,
            .content code {
                font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                font-size: 0.9em;
            }

            .content pre {
                overflow: auto;
                padding: 1rem;
                border-radius: 6px;
                background: rgba(32, 33, 36, 0.08);
            }

            .content table {
                width: 100%;
                border-collapse: collapse;
                font-size: 0.95em;
            }

            .content th,
            .content td {
                padding: 0.55rem 0.65rem;
                border-bottom: 1px solid rgba(32, 33, 36, 0.14);
                text-align: left;
                vertical-align: top;
            }

            @media (max-width: 620px) {
                .shell {
                    padding: 24px 18px 48px;
                }

                .content {
                    font-size: 1.1rem;
                    line-height: 1.68;
                }
            }
        </style>
        <div class="shell">
            <article>
                <header>
                    <div class="meta">${escapeHTML(metaParts.join(" · "))}</div>
                    <h1>${escapeHTML(pageTitle)}</h1>
                </header>
                <div class="content">${clone.innerHTML}</div>
            </article>
        </div>
    `;

    window.__quartzReaderMode = {
        overlay,
        documentOverflow: document.documentElement.style.overflow,
        bodyOverflow: document.body.style.overflow,
        bodyBackground: document.body.style.background
    };
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    document.body.style.background = "#fafaf8";
    document.body.appendChild(overlay);

    return { ok: true, title: pageTitle, wordCount };
})();
"""#

    static let exitScript = #"""
(() => {
    const readerMode = window.__quartzReaderMode;
    if (!readerMode) {
        return { ok: true, alreadyInactive: true };
    }

    readerMode.overlay?.remove();
    document.documentElement.style.overflow = readerMode.documentOverflow || "";
    document.body.style.overflow = readerMode.bodyOverflow || "";
    document.body.style.background = readerMode.bodyBackground || "";
    delete window.__quartzReaderMode;

    return { ok: true };
})();
"""#
}
