'use strict';
'require baseclass';
'require poll';
'require rpc';

var read = rpc.declare({object:'ows',method:'update_info'});
var action = rpc.declare({object:'ows',method:'update_action',params:['operation','value']});

var phases = {
    idle: _('Проверка ещё не запускалась'),
    checking: _('Проверяется релиз'),
    available: _('Доступна новая версия'),
    current: _('Установлена актуальная версия'),
    downloading: _('Скачивается архив'),
    installing: _('Идёт установка'),
    installed: _('Обновление установлено'),
    deferred: _('Установка отложена'),
    no_release: _('Стабильных релизов пока нет'),
    missing_key: _('Нужен доверенный ключ релизов'),
    missing_dependency: _('Нужны дополнительные утилиты'),
    unknown_version: _('Версия установленного OWS неизвестна'),
    interrupted: _('Обновление прервано'),
    error: _('Ошибка обновления')
};

return baseclass.extend({
    tab: function() {
        var root = E('div');
        var summary = E('dl');
        var status = E('p', {role:'status'});
        var notice = E('p', {role:'status'});
        var mode = E('select', {class:'cbi-input-select'}, [
            E('option', {value:'check'}, _('Проверять автоматически, устанавливать вручную')),
            E('option', {value:'auto'}, _('Автоматически устанавливать стабильные релизы')),
            E('option', {value:'off'}, _('Проверять вручную'))
        ]);
        var check = E('button', {type:'button',class:'cbi-button'}, _('Проверить сейчас'));
        var install = E('button', {type:'button',class:'cbi-button cbi-button-apply'}, _('Установить релиз'));
        var save = E('button', {type:'button',class:'cbi-button'}, _('Сохранить режим'));
        var data = {};
        var dirty = false;
        var sending = false;
        var next = 0;

        function busy() {
            return sending || data.queued || ['checking','downloading','installing'].includes(data.phase);
        }

        function controls() {
            check.disabled = !!(busy() || !data.trusted);
            install.disabled = !!(busy() || !data.trusted || !data.latest ||
                !['available','deferred'].includes(data.phase));
            mode.options[1].disabled = !data.trusted || !data.installed;
            save.disabled = !!(busy() || !dirty || (mode.value === 'auto' && mode.options[1].disabled));
        }

        function load() {
            return read().then(function(result) {
                data = result || {};
                if (!dirty) mode.value = data.mode || 'check';
                summary.replaceChildren(
                    E('dt', {}, _('Установленная версия')), E('dd', {}, data.installed || '—'),
                    E('dt', {}, _('Проверенная версия релиза')), E('dd', {}, data.latest || '—'),
                    E('dt', {}, _('Последняя проверка')), E('dd', {}, data.checked > 0 ?
                        new Date(data.checked * 1000).toLocaleString() : '—'),
                    E('dt', {}, _('Последняя попытка установки')), E('dd', {}, data.last_install ?
                        data.last_install + ' · ' + (data.install_result === 'installed' ? _('установлено') : _('ошибка')) : '—'),
                    E('dt', {}, _('Резервная копия')), E('dd', {}, data.backup ? E('code', {}, data.backup) : '—')
                );
                status.textContent = data.queued ? _('Операция ожидает запуска') :
                    [phases[data.phase],data.message].filter(Boolean).join(' · ');
                if (!data.trusted && data.phase !== 'missing_dependency') {
                    status.replaceChildren(_('Установите доверенный ключ релизов OWS в '),
                        E('code', {}, '/etc/ows/update/release.pub'));
                }
            }).catch(function() {
                notice.textContent = _('Не удалось прочитать состояние обновления');
            }).finally(function() {
                next = Date.now() + (busy() ? 4000 : 15000);
                controls();
            });
        }

        function submit(operation, value) {
            if (busy()) return;
            sending = true;
            controls();
            notice.textContent = '';
            action(operation, value || '').then(function(result) {
                if (!result.ok) throw new Error(result.error || _('Запрос отклонён'));
                if (operation === 'mode') {
                    dirty = false;
                    notice.textContent = _('Режим сохранён');
                }
            }).catch(function(error) {
                notice.textContent = error.message;
            }).finally(function() {
                sending = false;
                load();
            });
        }

        check.addEventListener('click', function() { submit('check'); });
        install.addEventListener('click', function() {
            if (window.confirm(_('Установить подписанный релиз OWS') + ' ' + data.latest + '?')) {
                submit('install', data.latest);
            }
        });
        mode.addEventListener('change', function() { dirty = mode.value !== data.mode; controls(); });
        save.addEventListener('click', function() {
            if (mode.value !== 'auto' || window.confirm(_('Разрешить автоматическую установку подписанных стабильных релизов?'))) {
                submit('mode', mode.value);
            }
        });
        controls();
        root.replaceChildren(
            summary, status,
            E('div', {class:'ows-actions'}, [check,install]),
            E('label', {class:'ows-field'}, [E('span', {}, _('Режим обновления')),mode]),
            save, notice
        );
        poll.add(function() {
            if (document.contains(root) && !root.closest('[hidden]') && Date.now() >= next) return load();
        }, 4);
        return {id:'update',label:_('Обновление'),activate:load,content:root};
    }
});
