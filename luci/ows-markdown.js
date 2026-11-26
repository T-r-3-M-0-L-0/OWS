'use strict';
'require baseclass';

function mdInline(text) {
    var nodes = [], last = 0;
    var re = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\([^\s)]+\))/g;
    var match;
    while ((match = re.exec(text))) {
        if (match.index > last) nodes.push(text.slice(last, match.index));
        var token = match[0];
        if (token.charAt(0) === '`') {
            nodes.push(E('code', {}, token.slice(1, -1)));
        } else if (token.slice(0, 2) === '**') {
            nodes.push(E('strong', {}, token.slice(2, -2)));
        } else if (token.charAt(0) === '*') {
            nodes.push(E('em', {}, token.slice(1, -1)));
        } else {
            var parts = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(token);
            var label = parts ? parts[1] : token;
            var href = parts ? parts[2] : '';
            if (/^https?:\/\//i.test(href)) {
                nodes.push(E('a', { href: href, target: '_blank', rel: 'noopener noreferrer' }, label));
            } else if (href && /^#[a-z0-9_-]+$/i.test(href)) {
                nodes.push(E('a', { href: href }, label));
            } else {
                nodes.push(label);
            }
        }
        last = match.index + token.length;
    }
    if (last < text.length) nodes.push(text.slice(last));
    return nodes;
}

function mdCells(line) {
    return line.trim().replace(/^\||\|$/g, '').replace(/\\\|/g, '\u0001').split('|').map(function(cell) {
        return cell.replace(/\u0001/g, '|').trim();
    });
}

function mdRender(source) {
    var lines = String(source || '').replace(/\r\n?/g, '\n').split('\n');
    var root = E('div', { class: 'ows-markdown' });
    var i = 0;
    while (i < lines.length) {
        var line = lines[i];
        if (!line.trim()) { i++; continue; }
        if (/^\s*```/.test(line)) {
            var code = [];
            i++;
            while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
            if (i < lines.length) i++;
            root.appendChild(E('pre', { class: 'ows-markdown-code' }, [E('code', {}, code.join('\n') + (code.length ? '\n' : ''))]));
            continue;
        }
        var heading = /^(#{1,6})\s+(.+)$/.exec(line);
        if (heading) {
            root.appendChild(E('h' + heading[1].length, {}, mdInline(heading[2])));
            i++; continue;
        }
        if (/^\s*(---|\*\*\*|___)\s*$/.test(line)) {
            root.appendChild(E('hr')); i++; continue;
        }
        if (line.indexOf('|') !== -1 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|?\s*$/.test(lines[i + 1]) && lines[i + 1].indexOf('-') !== -1) {
            var headers = mdCells(line);
            i += 2;
            var body = E('tbody');
            while (i < lines.length && lines[i].trim() && lines[i].indexOf('|') !== -1) {
                body.appendChild(E('tr', {}, mdCells(lines[i]).map(function(cell) { return E('td', {}, mdInline(cell)); })));
                i++;
            }
            root.appendChild(E('div', { class: 'ows-markdown-table-wrap' }, [E('table', { class: 'table ows-markdown-table' }, [
                E('thead', {}, [E('tr', {}, headers.map(function(cell) { return E('th', {}, mdInline(cell)); }))]), body
            ])]));
            continue;
        }
        if (/^\s*[-*]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)) {
            var ordered = /^\s*\d+\.\s+/.test(line);
            var list = E(ordered ? 'ol' : 'ul');
            var itemRe = ordered ? /^\s*\d+\.\s+/ : /^\s*[-*]\s+/;
            while (i < lines.length && itemRe.test(lines[i])) {
                list.appendChild(E('li', {}, mdInline(lines[i].replace(itemRe, ''))));
                i++;
            }
            root.appendChild(list);
            continue;
        }
        if (/^\s*>/.test(line)) {
            var quote = [];
            while (i < lines.length && /^\s*>/.test(lines[i])) {
                quote.push(lines[i].replace(/^\s*>\s?/, '')); i++;
            }
            root.appendChild(E('blockquote', {}, mdInline(quote.join(' '))));
            continue;
        }
        var paragraph = [line.trim()];
        i++;
        while (i < lines.length && lines[i].trim() && !/^\s*(```|#{1,6}\s|[-*]\s|\d+\.\s|>|---\s*$)/.test(lines[i])) {
            if (lines[i].indexOf('|') !== -1 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|?\s*$/.test(lines[i + 1])) break;
            paragraph.push(lines[i].trim()); i++;
        }
        root.appendChild(E('p', {}, mdInline(paragraph.join(' '))));
    }
    return root;
}

return baseclass.extend({ render: mdRender });
