'use strict';
'require baseclass';
'require poll';
'require rpc';
'require ui';
'require view.ows-ui as owsUI';

var field = owsUI.field, button = owsUI.button;

var presetList = rpc.declare({object:'ows',method:'zapret_presets'});
var presetPreview = rpc.declare({object:'ows',method:'zapret_preset_preview',params:['name']});
var presetWrite = rpc.declare({object:'ows',method:'zapret_preset_write',params:['operation','name','expected','selection']});
var constructorInfo = rpc.declare({object:'ows',method:'zapret_constructor',params:['topic','profile','list','page','run']});
var constructorAction = rpc.declare({object:'ows',method:'zapret_module_action',params:['id','action']});
var jobOutput = rpc.declare({object:'ows',method:'job_output',params:['job']});

function availablePresets() {
    return E('fieldset', {}, [
        E('legend', {}, _('Каталог пресетов')),
        E('ul', {}, [
            E('li', {}, [E('code', {}, 'all-off'), ' · ', _('Все стратегии выключены. Подходит для контрольной проверки соединения.')]),
            E('li', {}, [E('code', {}, 'hybrid-fz'), ' · ', _('Набор профилей FZ для общего трафика, YouTube, Discord и игр. Нужны соответствующие стратегии.')])
        ]),
        E('p', {}, _('Список справочный. Чтобы создать свой пресет, выберите установленные стратегии или вставьте их имена и сохраните набор.'))
    ]);
}

function number(value, min, max) {
    return E('input', {type:'number',class:'cbi-input-text',value:value,min:min,max:max,required:''});
}

function option(value, label) { return E('option', {value:value}, label || value); }

function chosen(select) {
    return Array.from(select.selectedOptions).map(function(item) { return item.value; }).join(',');
}

function table(headers, rows) {
    if (!rows.length) return E('p', {}, _('Данных пока нет'));
    return E('table', {class:'table'}, [
        E('thead', {}, E('tr', {}, headers.map(function(label) { return E('th', {scope:'col'}, label); }))),
        E('tbody', {}, rows.map(function(row) {
            return E('tr', {}, row.map(function(value) { return E('td', {}, String(value == null ? '—' : value)); }));
        }))
    ]);
}

function assertResult(result) {
    if (!result || result.error) throw new Error(result && result.error || _('Запрос не выполнен'));
    return result;
}

function timestamp(value) {
    return Number(value) > 0 ? new Date(Number(value) * 1000).toLocaleString() : '—';
}

function tsvRows(text) {
    var lines = (text || '').split('\n');
    var fields = lines.shift().split('\t');
    return lines.filter(Boolean).map(function(line) {
        var values = line.split('\t');
        return Object.fromEntries(fields.map(function(field, index) { return [field, values[index] || '']; }));
    });
}

function downloadReport(name, text) {
    var type = name.endsWith('.tsv') ? 'text/tab-separated-values' : 'text/plain';
    var url = URL.createObjectURL(new Blob([text], {type:type + ';charset=utf-8'}));
    var link = E('a', {href:url,download:name});
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

function toolAction(followJob, action) {
    return owsUI.job(constructorAction('zapret2', action), followJob, true).then(function(result) {
        if (result.status.phase !== 'done') {
            var message = result.output;
            try { message = JSON.parse(message).error || message; } catch (_) {}
            throw new Error(message || _('Действие завершилось с ошибкой.'));
        }
        return result;
    });
}

return baseclass.extend({
    profileRevision: function() {
        return presetList().then(assertResult).then(function(data) { return data.revision; });
    },

    presets: function(followJob, constructor, onApplied, options) {
        options = options || {};
        var names = E('select', {class:'cbi-input-select'});
        var title = E('input', {class:'cbi-input-text',maxlength:48});
        var search = E('input', {type:'search',class:'cbi-input-text',placeholder:_('Имя, протокол или порты')});
        var list = E('div', {class:'ows-strategy-grid'});
        var counts = E('p', {role:'status'});
        var review = E('details', {class:'ows-section',hidden:''});
        var pasted = E('textarea', {class:'cbi-input-textarea',rows:5,maxlength:8192});
        var feedback = owsUI.feedback();
        var snapshot;
        var selected = new Set();
        var busy = false;
        var pending;
        var comparison = this.comparison(followJob, {
            selection: function() { return Array.from(selected); },
            add: function(id) {
                if (busy || pending) return;
                if (!snapshot || !snapshot.profiles.some(function(item) { return item.id === id; })) {
                    feedback.show(_('Этот профиль уже отсутствует в конфигурации Zapret2.'));
                    return;
                }
                selected.add(id);
                renderProfiles();
                feedback.show(_('Профиль добавлен в выбранный набор.'));
            }
        });
        if (options.panel) comparison = options.panel(comparison);

        var refresh = button(_('Обновить состояние'), function() { load(); });
        var apply = button(_('Применить к Zapret2'), function() {
            if (!selected.size && !window.confirm(_('Выключить все стратегии Zapret2?'))) return;
            submit('select', '', snapshot.revision, selection());
        });
        var reset = button(_('Сбросить выбор'), function() { chooseCurrent(); renderProfiles(); });
        var usePasted = button(_('Выбрать профили из списка'), function() {
            var ids = pasted.value.split(/\r?\n/).map(function(id) { return id.trim(); })
                .filter(function(id) { return id && !id.startsWith('#'); });
            var known = new Set(snapshot.profiles.map(function(item) { return item.id; }));
            if (ids.some(function(id) { return !known.has(id); })) {
                feedback.show(_('В списке есть профили, которых нет в текущей конфигурации.'));
                return;
            }
            selected = new Set(ids);
            pastePanel.open = false;
            renderProfiles();
        });
        var pastePanel = E('details', {class:'ows-section'}, [E('summary', {}, _('Вставить список профилей')),
            field(_('По одному имени на строку'), pasted), E('div', {class:'ows-actions'}, usePasted)]);
        pastePanel.addEventListener('toggle', function() {
            if (pastePanel.open && snapshot) pasted.value = selection();
        });
        var open = button(_('Загрузить в конструктор'), loadPreset);
        var remove = button(_('Удалить пресет'), function() {
            if (window.confirm(_('Удалить выбранный пресет?'))) submit('delete', names.value, '', '');
        });
        var save = button(_('Сохранить набор'), function() {
            var name = title.value.trim();
            if (!/^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$/.test(name)) {
                feedback.show(_('Введите имя из строчных латинских букв, цифр и дефисов.'));
                return;
            }
            if (snapshot.presets.includes(name) && !window.confirm(_('Заменить сохранённый пресет?'))) return;
            submit('save', name, '', selection());
        });
        var savedPresets = E('fieldset', {hidden:''}, [E('legend', {}, _('Сохранённые пресеты')),
            field(_('Пресет'), names), E('div', {class:'ows-actions'}, [open, remove]),
            field(_('Имя пресета'), title), E('div', {class:'ows-actions'}, save)]);
        var profileEditor = E('fieldset', {hidden:''}, [E('legend', {}, _('Конструктор стратегий')),
            field(_('Поиск профилей'), search), counts, list, pastePanel, review,
            E('div', {class:'ows-actions'}, [apply, reset, refresh])]);

        function selection() {
            return snapshot.profiles.filter(function(item) { return selected.has(item.id); })
                .map(function(item) { return item.id; }).join('\n');
        }

        function changes() {
            return snapshot ? snapshot.profiles.filter(function(item) { return item.enabled !== selected.has(item.id); }) : [];
        }

        function controls() {
            var disabled = busy || !!pending || !snapshot;
            var changed = changes();
            savedPresets.hidden = profileEditor.hidden = !snapshot;
            refresh.disabled = busy || !!pending;
            apply.disabled = reset.disabled = disabled || !changed.length;
            names.disabled = title.disabled = search.disabled = pasted.disabled = usePasted.disabled = disabled;
            open.disabled = disabled || !names.value;
            remove.disabled = open.disabled || snapshot.native_presets.includes(names.value);
            save.disabled = disabled || snapshot.native_presets.includes(title.value.trim());
            list.querySelectorAll('input, button').forEach(function(control) { control.disabled = disabled; });
            comparison.sync();
            if (!snapshot) return;
            var enabled = snapshot.profiles.filter(function(item) { return item.enabled; }).length;
            counts.textContent = _('Включено сейчас') + ' · ' + enabled + ' / ' + snapshot.profiles.length +
                ' · ' + _('В выбранном наборе') + ' · ' + selected.size;
            review.hidden = !changed.length;
            if (changed.length) review.replaceChildren(
                E('summary', {}, _('Что изменится при применении') + ' · ' + changed.length),
                table([_('Профиль'), _('Действие')], changed.map(function(item) {
                    return [item.id, selected.has(item.id) ? _('Включить') : _('Выключить')];
                }))
            );
        }

        function chooseCurrent() {
            selected = new Set(snapshot.profiles.filter(function(item) { return item.enabled; })
                .map(function(item) { return item.id; }));
        }

        function renderProfiles() {
            var filter = search.value.trim().toLowerCase();
            var visible = snapshot.profiles.filter(function(item) {
                return [item.id,item.protocol,item.port,item.filter].join(' ').toLowerCase().includes(filter);
            });
            list.replaceChildren.apply(list, visible.length ? visible.map(function(item) {
                var checked = E('input', {type:'checkbox'});
                checked.checked = selected.has(item.id);
                checked.addEventListener('change', function() {
                    if (checked.checked) selected.add(item.id);
                    else selected.delete(item.id);
                    controls();
                });
                var description = [item.protocol && item.protocol.toUpperCase(), item.port, item.filter].filter(Boolean);
                var choice = E('label', {}, [checked, E('span', {}, [E('strong', {}, item.id), E('small', {}, description.join(' · '))])]);
                if (!options.tactics) { choice.className = 'ows-strategy-choice'; return choice; }
                var editTactic = button(_('Lua / blob'), function() {
                    options.tactics.openProfile(item.id);
                    sections.selectId(options.tactics.id);
                });
                editTactic.setAttribute('aria-label', _('Редактировать тактику %s').format(item.id));
                return E('div', {class:'ows-strategy-choice'}, [choice,editTactic]);
            }) : [E('p', {}, _('Профили не найдены.'))]);
            controls();
        }

        function load(preferred, resetSelection) {
            if (pending) return pending;
            var wanted = preferred || names.value;
            pending = presetList().then(assertResult).then(function(data) {
                var revised = snapshot && snapshot.revision !== data.revision;
                var states = revised && new Map(snapshot.profiles.map(function(item) { return [item.id,item.enabled]; }));
                var selectionChanged = states && (states.size !== data.profiles.length || data.profiles.some(function(item) {
                    return !states.has(item.id) || states.get(item.id) !== item.enabled;
                }));
                if (selectionChanged && changes().length && !resetSelection)
                    feedback.show(_('Штатная конфигурация изменилась. В конструкторе загружен актуальный набор.'));
                snapshot = data;
                if (selectionChanged || resetSelection || !list.hasChildNodes()) chooseCurrent();
                names.replaceChildren.apply(names, [option('', _('Выберите пресет'))].concat(data.presets.map(function(name) {
                    return option(name, data.native_presets.includes(name) ? name + ' · ' + _('штатный') : name);
                })));
                names.value = data.presets.includes(wanted) ? wanted : '';
                renderProfiles();
            }).catch(function(error) {
                snapshot = null;
                list.replaceChildren();
                feedback.show(error.message);
            }).finally(function() {
                pending = null;
                controls();
            });
            controls();
            return pending;
        }

        function loadPreset() {
            var name = names.value;
            if (!name || busy || !snapshot) return;
            busy = true;
            controls();
            feedback.start(_('Читаем пресет…'));
            return presetPreview(name).then(assertResult).then(function(data) {
                if (data.revision !== snapshot.revision)
                    throw new Error(_('Настройки Zapret2 изменились. Загрузите пресет повторно.'));
                selected = new Set(data.selected);
                title.value = snapshot.native_presets.includes(name) ? '' : name;
                renderProfiles();
                feedback.show(_('Набор загружен в конструктор.'));
            }).catch(function(error) {
                feedback.show(error.message);
                return load();
            }).finally(function() { busy = false; controls(); });
        }

        function submit(operation, name, expected, contents) {
            if (busy || pending || !snapshot) return;
            var applied = false;
            busy = true;
            controls();
            feedback.start(_('Выполняем запрос…'));
            return presetWrite(operation, name, expected, contents).then(assertResult).then(function(result) {
                if (!result.job) {
                    applied = operation === 'select';
                    feedback.show(_('Готово.'));
                    return;
                }
                return owsUI.job(result, followJob, true).then(function(job) {
                    applied = job.status.phase === 'applied';
                    if (applied) onApplied();
                    var messages = {
                        applied: _('Профили применены.'),
                        config_busy: _('Zapret2 занят другой операцией. Повторите после её завершения.'),
                        config_changed: _('Настройки Zapret2 изменились. Проверьте актуальный набор.'),
                        rolled_back: _('Запуск не прошёл проверку. Прежняя конфигурация восстановлена.')
                    };
                    feedback.show(messages[job.status.phase] || _('Профили не применены.'), job.output);
                });
            }).catch(function(error) { feedback.show(error.message); }).finally(function() {
                busy = false;
                return load(operation === 'save' ? name : '', applied);
            });
        }

        names.addEventListener('change', controls);
        title.addEventListener('input', controls);
        search.addEventListener('input', renderProfiles);
        controls();
        var sections = options.createTabs(_('Разделы конструктора пресетов'), [
            {id:'zapret2-selection',label:_('Пресеты и профили'),activate:function() { if (!busy) return load(); },
                content:E('div', {}, [availablePresets(), savedPresets, profileEditor])},
            options.tactics, comparison, this.classification(followJob), this.nfqueue(followJob, onApplied),
            {id:'zapret2-recovery',label:_('Восстановление профилей'),content:constructor.content,activate:constructor.activate}
        ].filter(Boolean), options.section, options.onSectionChange);
        return {
            id:'zapret2-presets',label:_('Конструктор пресетов'),
            selectedSection:sections.selectedId,
            activate:function() {
                if (!busy) return load().then(function() {
                    if (sections.selectedId() !== 'zapret2-selection') return sections.activate();
                });
            },
            content:E('div', {}, [sections.content, feedback.content])
        };
    },

    classification: function(followJob) {
        var domain = E('input', {type:'text',class:'cbi-input-text',placeholder:'example.org',maxlength:253,required:''});
        var repeats = number(3,1,5), timeout = number(5,2,30);
        timeout.step = '0.1';
        var ipv6 = E('input', {type:'checkbox'});
        var status = E('p', {role:'status'}), report = E('pre', {class:'ows-job-output'});
        var journal = E('pre', {class:'ows-job-output'}), feedback = owsUI.feedback();
        var pending, busy = false, loaded = false, state = {}, next = 0;
        var start = button(_('Начать полную классификацию'), function() {
            if (![domain,repeats,timeout].every(function(input) { return input.reportValidity(); })) return;
            if (!window.confirm(_('Полная классификация временно останавливает Zapret2. Запустить?'))) return;
            submit(['classify',domain.value.trim(),repeats.value,timeout.value,Number(ipv6.checked)].join(':'));
        });
        var stop = button(_('Остановить и восстановить Zapret2'), function() { submit('classify-stop'); });
        var save = button(_('Скачать отчёт'), function() { downloadReport('tspu-class-report.txt', state.report); });

        function controls() {
            domain.disabled = repeats.disabled = timeout.disabled = ipv6.disabled = start.disabled =
                busy || state.running || !state.available;
            stop.disabled = busy || !state.running;
            save.disabled = !state.report;
        }

        function load() {
            if (pending) return pending;
            loaded = true;
            pending = constructorInfo('classify-status').then(assertResult).then(function(data) {
                state = data;
                var values = Object.fromEntries((data.status || '').split('\n').filter(function(line) {
                    return /^(progress|elapsed)=/.test(line);
                }).map(function(line) { return [line.slice(0,line.indexOf('=')),line.slice(line.indexOf('=')+1)]; }));
                var labels = {running:_('Идёт классификация'),finished:_('Классификация завершена'),
                    stopped:_('Классификация остановлена'),failed:_('Ошибка классификации')};
                status.textContent = data.available ? [labels[data.state] || (data.running ?
                    labels.running : _('Готово к запуску')), values.progress ? _('Проверено') + ' ' + values.progress : '',
                    values.elapsed ? _('Прошло, с') + ' ' + values.elapsed : '',
                    data.service_running ? _('Zapret2 работает') : _('Zapret2 остановлен')].filter(Boolean).join(' · ') :
                    _('Компонент tspu-test недоступен.');
                report.textContent = data.report || _('Отчёт появится после завершения проверки.');
                journal.textContent = data.log || '—';
            }).catch(function(error) { status.textContent = error.message; }).finally(function() {
                next = Date.now() + (state.running ? 4000 : 15000);
                pending = null;
                controls();
            });
            return pending;
        }

        function submit(action) {
            if (busy) return;
            busy = true;
            controls();
            feedback.start(_('Ставим действие в очередь…'));
            return toolAction(followJob, action).then(function() { feedback.show(_('Команда выполнена.')); })
                .catch(function(error) { feedback.show(error.message); }).finally(function() { busy = false; return load(); });
        }

        var root = E('div', {}, [
            E('div', {class:'ows-fields'}, [field(_('Домен'),domain),field(_('Повторы'),repeats),field(_('Тайм-аут, с'),timeout),
                E('label', {}, [ipv6, ' ', _('Проверять IPv6')])]),
            E('div', {class:'ows-actions'}, [start,stop,button(_('Обновить состояние'),load),save]),
            status, feedback.content, report,
            E('details', {}, [E('summary', {}, _('Журнал классификации')),journal])
        ]);
        controls();
        poll.add(function() {
            if (loaded && document.contains(root) && !root.closest('[hidden]') && Date.now() >= next) return load();
        }, 4);
        return {id:'zapret2-classification',label:_('Классификация ТСПУ'),content:root,activate:load};
    },

    nfqueue: function(followJob, onApplied) {
        var table = E('div'), feedback = owsUI.feedback(), state = {}, busy = false;
        var optimize = button(_('Оптимизировать NFQUEUE'), function() {
            if (window.confirm(_('Рассчитать фильтры по портам включённых стратегий и перезапустить Zapret2, если они изменятся?')))
                submit('nfq-optimize');
        });
        var rollback = button(_('Откатить NFQUEUE'), function() {
            if (window.confirm(_('Восстановить сохранённые фильтры NFQUEUE и перезапустить Zapret2?')))
                submit('nfq-rollback');
        });
        function controls() {
            optimize.disabled = busy || state.tcp == null;
            rollback.disabled = busy || !state.can_rollback;
        }
        function load() {
            return constructorInfo('nfq-status').then(assertResult).then(function(data) {
                state = data;
                if (data.tcp == null) { table.textContent = _('Фильтры NFQUEUE недоступны.'); return; }
                table.replaceChildren(owsUI.table([_('Протокол'),_('Текущие порты'),_('Сохранённые для отката')],
                    [['TCP', data.tcp || '—', data.rollback_tcp || '—'], ['UDP', data.udp || '—', data.rollback_udp || '—']]));
            }).catch(function(error) { table.textContent = error.message; }).finally(controls);
        }
        function submit(action) {
            if (busy) return;
            busy = true;
            controls();
            feedback.start(_('Ставим изменение NFQUEUE в очередь…'));
            return toolAction(followJob, action).then(function(result) {
                feedback.show(action === 'nfq-optimize' ? _('Оптимизация завершена.') : _('Фильтры восстановлены.'), result.output);
                onApplied();
            }).catch(function(error) { feedback.show(error.message); }).finally(function() { busy = false; return load(); });
        }
        controls();
        return {id:'zapret2-nfqueue',label:_('Фильтры NFQUEUE'),activate:load,
            content:E('div', {}, [table,E('div', {class:'ows-actions'}, [optimize,rollback,button(_('Обновить состояние'),load)]),feedback.content])};
    },

    comparison: function(followJob, preset) {
        var root = E('div');
        var profiles = E('select', {class:'cbi-input-select',multiple:'',size:7});
        var lists = E('select', {class:'cbi-input-select',multiple:'',size:5});
        var allProfiles = E('input', {type:'checkbox'});
        var allLists = E('input', {type:'checkbox',checked:''});
        var mode = E('select', {class:'cbi-input-select'}, [option('tls13','TLS 1.3'),option('tls12','TLS 1.2'),
            option('http','HTTP'),option('quic','QUIC / HTTP/3')]);
        var method = E('select', {class:'cbi-input-select'}, [option('get','GET'),option('head','HEAD')]);
        var repeats = number(2,1,5), limit = number(20,0,10000), timeout = number(5,2,30);
        var status = E('p', {role:'status'}), notice = E('p', {role:'status'});
        var report = E('div'), schedule = E('div'), memory = E('pre', {class:'ows-job-output'});
        var running = false, busy = false, available = false, loaded = false;
        var statusPending, catalogPending, nextStatus = 0, current = {};
        var chosenManually = false;

        var start = button(_('Начать сравнение'), function() {
            var selected = allProfiles.checked ? 'all' : chosen(profiles);
            var targets = allLists.checked ? 'all' : chosen(lists);
            if (!selected || !targets) {
                notice.textContent = _('Выберите хотя бы одну стратегию и один список.');
                return;
            }
            if (![repeats,limit,timeout].every(function(input) { return input.reportValidity(); })) return;
            submit(['compare-start',selected,targets,mode.value,repeats.value,limit.value,timeout.value,method.value].join(':'));
        });
        var stop = button(_('Остановить сравнение'), function() { submit('compare-stop'); });
        var recover = button(_('Восстановить службу'), function() { submit('compare-recover'); });
        var usePreset = button(_('Выбрать набор конструктора'), function() {
            allProfiles.checked = false;
            chosenManually = false;
            selectPreset();
            controls();
        });
        var saveResults = button(_('Скачать сводку TSV'), function() { downloadReport('zapret2-comparison.tsv', current.results); });

        function controls() {
            var disabled = busy || running || !available;
            start.disabled = allProfiles.disabled = allLists.disabled = mode.disabled =
                method.disabled = repeats.disabled = limit.disabled = timeout.disabled = disabled;
            profiles.disabled = disabled || allProfiles.checked;
            lists.disabled = disabled || allLists.checked;
            usePreset.disabled = disabled;
            stop.disabled = busy || !running;
            recover.hidden = current.state !== 'recovery_required';
            recover.disabled = busy || running;
            saveResults.disabled = !current.results;
        }

        function submit(action, after) {
            if (busy) return;
            busy = true;
            controls();
            notice.textContent = _('Ставим действие в очередь…');
            return owsUI.job(constructorAction('zapret2', action), followJob, true).then(function(result) {
                notice.textContent = result.status.phase === 'done' ? _('Действие выполнено') :
                    result.output || _('Действие завершилось с ошибкой');
                busy = false;
                refresh();
                if (after) after();
            }).catch(function(error) { notice.textContent = error.message; }).finally(function() {
                busy = false;
                controls();
            });
        }

        function showDetails(profile, list, page, run) {
            return constructorInfo('compare-details', profile, list, page, run).then(assertResult).then(function(data) {
                var detail = tsvRows(data.rows);
                var previous = button(_('Назад'), function() { return showDetails(profile, list, data.page - 1, data.run); });
                var next = button(_('Дальше'), function() { return showDetails(profile, list, data.page + 1, data.run); });
                previous.disabled = data.page === 0;
                next.disabled = !data.more;
                ui.showModal(profile === 'baseline' ? _('Контрольный прогон') : profile, [
                    E('p', {}, list + ' · ' + _('Страница') + ' ' + (data.page + 1)),
                    E('div', {class:'ows-comparison-table'}, [owsUI.table(
                        [_('Домен'),_('Попытка'),_('Результат'),_('curl'),_('HTTP'),_('Байты'),_('Секунды'),_('Маршрут')],
                        detail.map(function(row) {
                            return [row.domain, row.attempt, row.result, row.curl_rc, row.http_code, row.bytes, row.seconds, row.route];
                        }))]),
                    detail.length ? '' : E('p', {}, _('В отчёте пока нет запросов для этой пары.')),
                    E('div', {class:'ows-actions'}, [
                        previous, next,
                        button(_('Скачать страницу TSV'), function() { downloadReport('zapret2-domains.tsv', data.rows); }),
                        button(_('Закрыть'), ui.hideModal)
                    ])
                ]);
            }).catch(function(error) { notice.textContent = error.message; });
        }

        function renderReport(data) {
            var grouped = new Map(), listsInReport = new Set();
            tsvRows(data.results).forEach(function(row) {
                if (!grouped.has(row.profile)) grouped.set(row.profile, new Map());
                grouped.get(row.profile).set(row.list, row);
                listsInReport.add(row.list);
            });
            var names = Array.from(listsInReport);
            var metrics = new Map((data.scores || []).map(function(item) { return [item.id, item]; }));
            grouped.forEach(function(_, id) { if (!metrics.has(id)) metrics.set(id, {id:id,pass:0,tested:0}); });
            var scores = Array.from(metrics.values()).sort(function(a, b) {
                if (a.id === 'baseline') return -1;
                if (b.id === 'baseline') return 1;
                return Number(b.pass) / (Number(b.tested) || 1) - Number(a.pass) / (Number(a.tested) || 1);
            });
            var baseline = scores.find(function(item) { return item.id === 'baseline'; });
            var rows = scores.map(function(item) {
                var isBaseline = item.id === 'baseline';
                var group = grouped.get(item.id);
                var delta = '—';
                if (!isBaseline && baseline && Number(item.tested) && Number(item.tested) === Number(baseline.tested)) {
                    var difference = Number(item.pass) - Number(baseline.pass);
                    delta = difference > 0 ? '+' + difference : String(difference);
                }
                var name = isBaseline ? _('Контрольный прогон') : item.id;
                var profile = E('span', {}, [
                    name, isBaseline ? '' : ' ',
                    isBaseline ? '' : button(_('В набор'), function() { preset.add(item.id); })
                ]);
                return [profile, item.pass + '/' + item.tested, delta].concat(names.map(function(list) {
                    var row = group && group.get(list);
                    if (!row) return '—';
                    var count = row.coverage.split('/')[1] || '0';
                    var cell = button(row.pass + '/' + count, function() { return showDetails(item.id, list, 0, data.run || ''); });
                    var controlRow = grouped.get('baseline') && grouped.get('baseline').get(list);
                    if (/^ALL_PASS/.test(row.verdict)) cell.classList.add('ows-comparison-pass');
                    else if (controlRow && Number(row.pass) > Number(controlRow.pass)) cell.classList.add('ows-comparison-improved');
                    else if (/^(FAIL|ERROR|CHECK_ERROR)$/.test(row.verdict)) cell.classList.add('ows-comparison-fail');
                    cell.title = [row.verdict, _('Покрытие') + ' ' + row.coverage,
                        _('Нестабильные') + ' ' + row.unstable, 'DNS ' + row.dns_error, 'HTTP ' + row.http_response].join(' · ');
                    return cell;
                }));
            });
            report.replaceChildren(
                rows.length ? E('div', {class:'ows-comparison-table'}, [owsUI.table(
                    [_('Стратегия'),_('Уникальные домены'),_('Разница с контролем')].concat(names), rows)]) :
                    E('p', {}, _('Данных сравнения пока нет.')),
                data.log ? E('details', {}, [E('summary', {}, _('Журнал сравнения')), E('pre', {class:'ows-job-output'}, data.log)]) : '',
                E('details', {}, [E('summary', {}, _('История')), table([_('Начало'),_('Режим'),_('Состояние')],
                    (data.history || []).map(function(item) { return [timestamp(item.started),item.mode,item.state]; }))])
            );
        }

        function refresh() {
            if (statusPending) return statusPending;
            statusPending = constructorInfo('compare-status').then(assertResult).then(function(data) {
                current = data;
                running = !!data.running;
                if (!data.available) {
                    status.textContent = _('Для сравнения нужен комплект strategy-check.');
                    return;
                }
                var labels = {
                    idle:_('Ожидание запуска'), preparing:_('Подготовка'), running:_('Идёт сравнение'),
                    restoring:_('Восстановление службы'),
                    finished:_('Сравнение завершено'), stopped:_('Сравнение остановлено'), failed:_('Ошибка сравнения'),
                    interrupted:_('Сравнение прервано'), recovery_required:_('Требуется восстановление службы')
                };
                var phases = {compile:_('Подготовка профиля'),dns:_('Разрешение домена'),baseline:_('Контрольный прогон'),
                    test:_('Проверка профиля'),finished:_('Запросы завершены')};
                var progress = (data.progress || '').trim().split('\t');
                var elapsed = Number(data.started) > 0 ? Math.max(0,
                    Math.round((Number(data.finished) || Date.now()/1000) - Number(data.started))) : null;
                status.textContent = [labels[data.state] || data.state, data.mode, data.request && data.request.toUpperCase(),
                    data.running ? phases[progress[0]] || progress[0] : '',
                    data.running && progress[4] ? [progress[2],progress[3] + '/' + progress[4]].filter(Boolean).join(' ') : '',
                    elapsed !== null ? _('Прошло, с') + ' ' + elapsed : '',
                    data.exit_code && data.exit_code !== '0' ? _('Код завершения') + ' ' + data.exit_code : ''].filter(Boolean).join(' · ');
                renderReport(data);
            }).catch(function(error) { status.textContent = error.message; }).finally(function() {
                nextStatus = Date.now() + (running ? 4000 : 15000);
                statusPending = null;
                controls();
            });
            return statusPending;
        }

        function loadSchedule() {
            return constructorInfo('compare-schedule').then(assertResult).then(function(data) {
                if (!data.available) {
                    schedule.replaceChildren(E('p', {}, _('Для расписания нужен healthcheck из strategy-check.')));
                    return;
                }
                var enabled = E('input', {type:'checkbox'}), autopromote = E('input', {type:'checkbox'});
                var cooldown = number(data.cooldown_hours,1,168), cap = number(data.limit,0,20);
                enabled.checked = !!data.enabled;
                autopromote.disabled = !data.confirmed_autopromote;
                autopromote.checked = !!data.autopromote && !autopromote.disabled;
                schedule.replaceChildren(
                    E('p', {}, data.running ? _('Идёт проверка по расписанию.') :
                        data.enabled ? _('Автоподбор включён.') : _('Автоподбор выключен.')),
                    field(_('Ежечасная проверка в :17'),enabled),
                    field(_('Автоприменение после повторной проверки'),autopromote),
                    field(_('Интервал между применениями, ч'),cooldown),
                    field(_('Лимит применений за день'),cap),
                    E('div', {class:'ows-actions'}, [
                        button(_('Сохранить расписание'), function() {
                            if (!cooldown.checkValidity() || !cap.checkValidity()) return;
                            if (autopromote.checked && !window.confirm(_('Разрешить автоматическое применение подтверждённых стратегий?'))) return;
                            submit(['schedule-set',Number(enabled.checked),Number(autopromote.checked),cooldown.value,cap.value].join(':'),loadSchedule);
                        }),
                        button(_('Проверить сейчас'), function() { submit('health-run',loadSchedule); }),
                        button(_('Обновить журналы'),loadSchedule)
                    ]),
                    data.health_log ? E('details', {}, [E('summary', {}, _('Журнал мониторинга')),E('pre', {class:'ows-job-output'}, data.health_log)]) : '',
                    data.log ? E('details', {}, [E('summary', {}, _('Журнал автоподбора')),E('pre', {class:'ows-job-output'}, data.log)]) : ''
                );
            }).catch(function(error) { schedule.textContent = error.message; });
        }

        function selectPreset() {
            var active = new Set(preset.selection());
            Array.from(profiles.options).forEach(function(node) { node.selected = active.has(node.value); });
        }

        function loadCatalog() {
            if (catalogPending) return catalogPending;
            var selectedProfiles = new Set(Array.from(profiles.selectedOptions).map(function(item) { return item.value; }));
            var selectedLists = new Set(Array.from(lists.selectedOptions).map(function(item) { return item.value; }));
            catalogPending = constructorInfo('compare-catalog').then(assertResult).then(function(data) {
                available = !!data.available;
                profiles.replaceChildren.apply(profiles, (data.profiles || []).map(function(item) {
                    var meta = [item.protocol,item.port].filter(Boolean).join('/');
                    var node = option(item.id, [item.id,meta].filter(Boolean).join(' · '));
                    node.selected = selectedProfiles.has(item.id);
                    return node;
                }));
                if (!chosenManually) selectPreset();
                lists.replaceChildren.apply(lists, (data.lists || []).map(function(item) {
                    var count = data.list_counts && data.list_counts[item];
                    var node = option(item, count ? item + ' · ' + count : item);
                    node.selected = selectedLists.has(item);
                    return node;
                }));
                mode.querySelector('option[value="quic"]').disabled = !data.http3;
                if (mode.value === 'quic' && !data.http3) mode.value = 'tls13';
            }).catch(function(error) { notice.textContent = error.message; }).finally(function() {
                catalogPending = null;
                controls();
            });
            return catalogPending;
        }

        function load() {
            loaded = true;
            controls();
            return Promise.all([refresh(),loadSchedule(),loadCatalog()]);
        }

        profiles.addEventListener('change', function() { chosenManually = true; });
        allProfiles.addEventListener('change', controls);
        allLists.addEventListener('change', controls);
        var memoryPanel = E('details', {}, [E('summary', {}, _('Память успешных стратегий')), memory]);
        memoryPanel.addEventListener('toggle', function() {
            if (memoryPanel.open) constructorInfo('compare-memory').then(assertResult).then(function(data) {
                memory.textContent = data.memory || _('Подтверждённых результатов пока нет.');
            }).catch(function(error) { memory.textContent = error.message; });
        });
        root.replaceChildren(
            E('div', {class:'ows-fields'}, [
                E('div', {}, [E('label', {}, [allProfiles, ' ', _('Все профили')]),field(_('Стратегии'),profiles)]),
                E('div', {}, [E('label', {}, [allLists, ' ', _('Все списки')]),field(_('Доменные списки'),lists)]),
                field(_('Протокол'),mode),field(_('Запрос'),method),field(_('Повторы'),repeats),
                field(_('Доменов на список (0 — все)'),limit),field(_('Тайм-аут, с'),timeout)
            ]),
            E('div', {class:'ows-actions'}, [start,stop,recover,usePreset,button(_('Обновить каталог'),loadCatalog),
                button(_('Обновить результаты'),refresh),saveResults]),
            status,notice,report,E('h4', {}, _('Расписание проверок')),schedule,memoryPanel
        );
        controls();
        poll.add(function() {
            if (loaded && document.contains(root) && !root.closest('[hidden]') && root.getClientRects().length &&
                Date.now() >= nextStatus) return refresh();
        }, 4);
        return {id:'zapret2-comparison',label:_('Сравнение стратегий'),content:root,activate:load,
            sync:function() { if (!chosenManually) selectPreset(); }};
    }
});
