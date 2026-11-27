'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var preview = rpc.declare({object:'ows', method:'cleanup_preview'});
var apply = rpc.declare({object:'ows', method:'cleanup_apply', params:['revision']});

return baseclass.extend({
    panel: function(followJob) {
        var summary = E('p', {role:'status'});
        var results = E('div');
        var feedback = owsUI.feedback();
        var check = owsUI.button(_('Проверить остатки'), load);
        var clean = owsUI.button(_('Удалить найденные остатки'), submit, true);
        var plan;
        var busy = false;

        function setBusy(value) {
            busy = check.disabled = value;
            clean.disabled = value || !plan || !plan.ready;
        }

        function load() {
            if (busy) return;
            plan = null;
            setBusy(true);
            summary.textContent = _('Проверяем файлы и зависимости…');
            results.replaceChildren();
            return preview().then(owsUI.checked).then(function(data) {
                if (!Array.isArray(data.paths) || typeof data.ready !== 'boolean' ||
                    !data.paths.every(function(item) {
                        return item && typeof item.path === 'string' && typeof item.removable === 'boolean';
                    }) || data.ready !== data.paths.some(function(item) { return item.removable; }) ||
                    (data.ready && !/^[0-9a-f]{64}$/.test(data.revision))) {
                    throw new Error(_('OWS вернул неполный план очистки. Повторите проверку.'));
                }
                plan = data;
                summary.textContent = data.ready ? _('Проверьте список перед удалением.') : data.paths.length ?
                    _('Сейчас очистка недоступна. Причины указаны в списке.') : _('Известных остатков Zapret-Manager не найдено.');
                if (!data.paths.length) return;
                results.replaceChildren(owsUI.table([_('Путь'), _('Результат проверки')], data.paths.map(function(item) {
                    return [item.path, item.removable ? _('Можно удалить') : item.reason];
                })));
            }).catch(function(error) {
                summary.textContent = error.message || _('Не удалось проверить остатки.');
            }).finally(function() { setBusy(false); });
        }

        function submit() {
            if (busy || !plan || !plan.ready) return;
            if (!window.confirm(_('Удалить файлы, отмеченные в плане как доступные для очистки? Отменить удаление нельзя.'))) return;
            setBusy(true);
            feedback.start(_('Ставим очистку в очередь…'));
            return owsUI.job(apply(plan.revision), followJob, true).then(function(result) {
                owsUI.showResult(feedback, result, _('Очистка не завершилась. Проверьте журнал.'));
            }).catch(function(error) { feedback.show(error.message); }).finally(function() {
                setBusy(false);
                return load();
            });
        }

        return E('details', {class:'ows-section'}, [
            E('summary', {}, _('Остатки Zapret-Manager')),
            E('p', {}, _('После переноса настроек и штатного удаления старой панели можно убрать её оставшиеся файлы.')),
            E('div', {class:'ows-actions'}, [check, clean]),
            summary, results, feedback.content
        ]);
    }
});
