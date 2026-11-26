'use strict';
'require baseclass';
'require rpc';

var hasAccess = rpc.declare({
    object: 'session', method: 'access', params: ['scope', 'object', 'function'], expect: { access: false }
});

return baseclass.extend({
    tab: function(options) {
        var panel = E('div', { class: 'ows-native' });
        var label = options.label || _('Штатные настройки');
        var pending, frame, revision, pages, selectedPage = 0;
        function fitFrame(frame) {
            var doc = frame.contentDocument;
            if (!doc || !doc.getElementById('view')) return;

            var style = doc.createElement('style');
            style.textContent = [
                'body { margin: 0 !important; padding: 0 !important; }',
                'body > header, body > footer, #mainmenu, #tabmenu, #indicator, #indicators,',
                '.main-left, .showSide { display: none !important; }',
                '#maincontent { margin: 0 !important; padding: 0 !important; max-width: none !important; }'
            ].join('\n');
            doc.head.appendChild(style);

        }

        function load() {
            if (pending) return pending;
            if (frame && !options.revision) return Promise.resolve();
            if (!frame) panel.replaceChildren(E('p', { role: 'status' }, _('Загружаем штатный интерфейс…')));
            var access = frame ? Promise.resolve(true) : Promise.resolve().then(options.available || function() { return true; })
                .then(function(available) {
                    if (!available) throw new Error(_('Установите пакет штатного интерфейса во вкладке «Служба и пакеты».'));
                    if (options.pages) pages = options.pages(available);
                    return hasAccess('access-group', options.acl, 'read');
                });
            pending = access.then(function(allowed) {
                if (!allowed) throw new Error(_('У этой учётной записи нет доступа к штатному интерфейсу.'));
                return options.revision ? options.revision() : null;
            }).then(function(current) {
                if (frame && revision === current) return;
                // A LuCI view owns #view during construction and may reload its document after applying changes.
                var route = pages ? pages[selectedPage].route : options.route;
                frame = E('iframe', {
                    class: 'ows-native-frame', title: label,
                    src: L.url('admin', 'services', route)
                });
                frame.addEventListener('load', function(event) {
                    fitFrame(event.currentTarget);
                    if (options.onLoad) options.onLoad();
                });
                revision = current;
                if (pages) {
                    var select = E('select', { class: 'cbi-input-select', 'aria-label': _('Раздел штатного интерфейса') },
                        pages.map(function(page, index) { return E('option', { value: index }, page.label); }));
                    select.value = selectedPage;
                    select.addEventListener('change', function() {
                        selectedPage = Number(select.value);
                        frame.src = L.url('admin', 'services', pages[selectedPage].route);
                    });
                    panel.replaceChildren(select, frame);
                } else {
                    panel.replaceChildren(frame);
                }
            }).catch(function(error) {
                if (frame) return;
                panel.replaceChildren(E('p', { role: 'alert' }, error.message || _('Штатный интерфейс недоступен.')),
                    E('button', { type: 'button', class: 'cbi-button', click: load }, _('Повторить')));
            }).finally(function() {
                pending = null;
            });
            return pending;
        }

        return { id: options.id, label: label, content: panel, activate: load };
    }
});
