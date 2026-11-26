'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var catalog = rpc.declare({object:'ows', method:'catalog'});
var parameters = ['profile','line','action','blob','expected'];
var preview = rpc.declare({object:'ows', method:'preview', params:parameters});
var applyAction = rpc.declare({object:'ows', method:'apply_action', params:parameters});
var actions = ['fake','multisplit','multidisorder'];

function option(value, label) { return E('option', {value:value}, label || value); }
function select() { return E('select', {class:'cbi-input-select'}); }

function blobUsage(profiles) {
    var usage = new Map();
    for (var item of profiles) {
        var refs = (item.script || '').matchAll(/(?:^|[\s:])(?:blob|seqovl_pattern)=([A-Za-z0-9_]+)(?=[:\s]|$)/g);
        for (var ref of refs) {
            if (!usage.has(ref[1])) usage.set(ref[1], new Set());
            usage.get(ref[1]).add(item.name);
        }
    }
    return usage;
}

return baseclass.extend({
    tab: function(followJob, options) {
        var profile = select(), line = select(), action = select(), blob = select();
        action.replaceChildren.apply(action, actions.map(function(name) { return option(name); }));
        var notice = E('p', {role:'status'});
        var feedback = owsUI.feedback();
        var review = E('div', {class:'ows-review'});
        var search = E('input', {type:'search',class:'cbi-input-text'});
        var resources = E('div', {class:'ows-service-table'});
        var resourcePanel = {id:'zapret2-resources',label:_('Blob-файлы'),content:[owsUI.field(_('Поиск blob'), search),resources]};
        if (options.panel) resourcePanel = options.panel(resourcePanel);
        var summary = E('summary', {}, resourcePanel.label);
        var resourceDetails = E('details', {class:'ows-section'}, [summary].concat(resourcePanel.content || []));
        resourceDetails.open = !!options.showResources;
        var profiles = new Map(), blobs = [], usage = new Map(), revision;
        var desiredProfile, request, pendingApply = false, approved, generation = 0;

        function locked() { return !!request || pendingApply || !profiles.has(profile.value); }

        function renderResources() {
            if (!resourceDetails.open) return;
            var keyword = search.value.trim().toLowerCase();
            var rows = blobs.filter(function(name) { return name.toLowerCase().includes(keyword); }).map(function(name) {
                var current = usage.get(name);
                return [E('code', {}, name), current ? Array.from(current).join(', ') : '—',
                    owsUI.button(_('Выбрать'), function() {
                        if (locked() || action.value !== 'fake') return;
                        blob.value = name;
                        invalidate();
                        blob.focus();
                    }, locked() || action.value !== 'fake' || blob.value === name)];
            });
            resources.replaceChildren(rows.length ? owsUI.table([_('Имя'),_('Используется в тактиках'),_('Для действия fake')], rows) :
                E('p', {}, keyword ? _('Blob с таким именем не найден.') : _('Нет доступных blob.')));
        }

        function controls() {
            var disabled = locked();
            profile.disabled = line.disabled = action.disabled = disabled;
            blob.disabled = disabled || action.value !== 'fake';
            refresh.disabled = !!request || pendingApply;
            reviewButton.disabled = disabled || (!blob.disabled && !blob.value);
            applyButton.disabled = disabled || !approved;
            renderResources();
        }

        function invalidate() {
            generation++;
            approved = null;
            review.replaceChildren();
            feedback.start('');
            controls();
        }

        function scriptLines() { return (profiles.get(profile.value) || '').split('\n'); }

        function loadAction() {
            var current = scriptLines()[Number(line.value) - 1] || '';
            var name = current.trim().match(/^--lua-desync=([A-Za-z0-9_]+)/);
            var assigned = current.match(/:blob=([A-Za-z0-9_]+)(?=:|\s|$)/);
            action.value = name && actions.includes(name[1]) ? name[1] : 'fake';
            blob.value = assigned && blobs.includes(assigned[1]) ? assigned[1] : '';
            invalidate();
        }

        function loadLines(useLine) {
            var items = [option('0', _('Добавить действие в конец'))];
            scriptLines().forEach(function(text, index) {
                if (/^\s*--lua-desync=[A-Za-z0-9_]+(?::[^\s"'\\]+)?\s*$/.test(text))
                    items.push(option(String(index + 1), text.trim()));
            });
            line.replaceChildren.apply(line, items);
            line.value = Array.from(line.options).some(function(item) { return item.value === useLine; }) ? useLine : '0';
            loadAction();
        }

        function load() {
            if (request || pendingApply) return request;
            notice.textContent = _('Читаем тактики Zapret2…');
            request = catalog().then(owsUI.checked).then(function(data) {
                var items = data.profiles || [];
                var current = profile.value, chosen = desiredProfile || current, previousLine = line.value;
                revision = data.revision;
                profiles = new Map(items.map(function(item) { return [item.name, item.script]; }));
                blobs = Array.from(new Set(data.blobs || []));
                usage = blobUsage(items);
                profile.replaceChildren.apply(profile, items.map(function(item) { return option(item.name); }));
                blob.replaceChildren.apply(blob, [option('', _('Выберите blob'))].concat(blobs.map(function(name) { return option(name); })));
                profile.value = profiles.has(chosen) ? chosen : (items[0] || {}).name || '';
                notice.textContent = !items.length ? _('В конфигурации нет тактик.') :
                    desiredProfile && !profiles.has(chosen) ? _('Выбранная тактика отсутствует в конфигурации.') : '';
                desiredProfile = null;
                summary.textContent = resourcePanel.label + ' · ' + blobs.length;
                loadLines(profile.value === current ? previousLine : '0');
            }).catch(function(error) {
                profiles.clear(); blobs = []; usage.clear();
                profile.replaceChildren(); line.replaceChildren(); blob.replaceChildren();
                summary.textContent = resourcePanel.label;
                notice.textContent = error.message || _('Не удалось прочитать тактики.');
            }).finally(function() { request = null; controls(); });
            invalidate();
            return request;
        }

        function inspect() {
            if (reviewButton.disabled) return;
            invalidate();
            var token = generation;
            var args = [profile.value,line.value,action.value,blob.disabled ? '' : blob.value,revision];
            feedback.start(_('Проверяем выбранное действие…'));
            return preview.apply(null, args).then(owsUI.checked).then(function(result) {
                if (token !== generation) return;
                if (result.before === result.after) { feedback.show(_('Изменений нет.')); return; }
                feedback.start('');
                review.replaceChildren(
                    E('div', {}, [E('h4', {}, _('До')), E('pre', {}, String(result.before || ''))]),
                    E('div', {}, [E('h4', {}, _('После')), E('pre', {}, String(result.after || ''))])
                );
                approved = args;
                controls();
            }).catch(function(error) {
                if (token === generation) feedback.show(error.message || _('Не удалось получить предпросмотр.'));
            });
        }

        function commit() {
            if (applyButton.disabled || !approved) return;
            var args = approved;
            pendingApply = true;
            invalidate();
            feedback.start(_('Ставим изменение в очередь…'));
            return owsUI.job(applyAction.apply(null, args), followJob, true).then(function(result) {
                pendingApply = false;
                if (result.status.phase !== 'applied') {
                    owsUI.showResult(feedback, result, _('Изменение тактики не применено.'));
                    return;
                }
                options.onApplied();
                return load().then(function() { feedback.show(_('Тактика обновлена.'), result.output); });
            }).catch(function(error) { feedback.show(error.message); })
                .finally(function() { pendingApply = false; controls(); });
        }

        var refresh = owsUI.button(_('Обновить тактики'), load);
        var reviewButton = owsUI.button(_('Предпросмотр'), inspect);
        var applyButton = owsUI.button(_('Применить тактику'), commit);
        profile.addEventListener('change', function() { loadLines(); });
        line.addEventListener('change', loadAction);
        action.addEventListener('change', invalidate);
        blob.addEventListener('change', invalidate);
        search.addEventListener('input', renderResources);
        resourceDetails.addEventListener('toggle', function() {
            if (!resourceDetails.open) return;
            renderResources();
            if (resourcePanel.activate) resourcePanel.activate();
        });
        controls();
        return {id:'zapret2-tactics',label:_('Тактики и ресурсы'),activate:load,
            openProfile:function(name) { desiredProfile = name; },
            content:E('div', {}, [notice,
                E('div', {class:'ows-fields'}, [owsUI.field(_('Тактика'), profile),owsUI.field(_('Шаг'), line),
                    owsUI.field(_('Lua-действие'), action),owsUI.field(_('Blob для fake'), blob)]),
                E('div', {class:'ows-actions'}, [reviewButton,applyButton,refresh]), review, feedback.content, resourceDetails])};
    }
});
