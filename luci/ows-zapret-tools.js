'use strict';
'require baseclass';
'require poll';
'require rpc';

var presetList = rpc.declare({object:'ows',method:'zapret_presets'});
var presetPreview = rpc.declare({object:'ows',method:'zapret_preset_preview',params:['name']});
var presetWrite = rpc.declare({object:'ows',method:'zapret_preset_write',params:['operation','name','expected','selection']});
var constructorInfo = rpc.declare({object:'ows',method:'zapret_constructor',params:['topic']});
var constructorAction = rpc.declare({object:'ows',method:'zapret_module_action',params:['id','action']});
var jobOutput = rpc.declare({object:'ows',method:'job_output',params:['job']});

function button(label, click) {
    var node = E('button', {type:'button',class:'cbi-button'}, label);
    node.addEventListener('click', click);
    return node;
}

function field(label, control) {
    return E('label', {class:'ows-field'}, [E('span', {}, label), control]);
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

return baseclass.extend({
    presets: function(followJob) {
        var names = E('select', {class:'cbi-input-select'});
        var title = E('input', {class:'cbi-input-text',maxlength:48,pattern:'[a-z0-9][a-z0-9-]*'});
        var selection = E('textarea', {class:'cbi-input-textarea',rows:7,maxlength:8192});
        var previewBox = E('div');
        var notice = E('p', {role:'status'});
        var current = [];
        var approved;
        var busy = false;
        var apply = button(_('Применить'), function() {
            if (!approved || names.value !== approved.name || busy) return;
            send('apply', approved.name, approved.token, '');
        });
        apply.disabled = true;

        function resetPreview() {
            approved = null;
            apply.disabled = true;
            previewBox.replaceChildren();
        }

        function load(preferred) {
            var selected = preferred || names.value;
            return presetList().then(assertResult).then(function(data) {
                current = (data.profiles || []).filter(function(item) { return item.enabled; })
                    .map(function(item) { return item.id; });
                names.replaceChildren.apply(names, [option('', _('Выберите пресет'))].concat((data.presets || []).map(function(name) { return option(name); })));
                names.value = (data.presets || []).includes(selected) ? selected : '';
            }).catch(function(error) { notice.textContent = error.message; });
        }

        function send(operation, name, expected, contents) {
            busy = true;
            resetPreview();
            notice.textContent = _('Выполняем запрос…');
            presetWrite(operation, name, expected, contents).then(assertResult).then(function(result) {
                if (result.job) {
                    followJob(result.job, function(status) {
                        busy = false;
                        notice.textContent = status.phase === 'applied' ? _('Пресет применён') : _('Применение не завершено');
                        load(name);
                    });
                    return;
                }
                busy = false;
                notice.textContent = _('Готово');
                load(operation === 'save' ? name : '');
            }).catch(function(error) { busy = false; notice.textContent = error.message; });
        }

        names.addEventListener('change', resetPreview);
        return {
            id:'zapret2-presets',label:_('Пресеты'),activate:load,
            content:E('div', {}, [
                field(_('Пресет'), names),
                E('div', {class:'ows-actions'}, [
                    button(_('Предпросмотр'), function() {
                        var name = names.value;
                        if (!name || busy) return;
                        resetPreview();
                        presetPreview(name).then(assertResult).then(function(data) {
                            if (names.value !== name || busy) return;
                            var changes = data.changes || [];
                            previewBox.replaceChildren(changes.length ? table([_('Стратегия'),_('После применения')],
                                changes.map(function(item) { return [item.id,item.enabled ? _('Включена') : _('Выключена')]; })) :
                                E('p', {}, _('Состояние уже совпадает с пресетом.')));
                            approved = {name:name,token:data.token};
                            apply.disabled = !changes.length;
                        }).catch(function(error) { notice.textContent = error.message; });
                    }), apply,
                    button(_('Удалить'), function() {
                        if (names.value && !busy && window.confirm(_('Удалить выбранный пресет?'))) send('delete', names.value, '', '');
                    })
                ]),
                previewBox,
                field(_('Имя нового пресета'), title),
                field(_('Стратегии, по одной на строку'), selection),
                E('div', {class:'ows-actions'}, [
                    button(_('Взять текущий набор'), function() { selection.value = current.join('\n'); }),
                    button(_('Сохранить пресет'), function() {
                        var name = title.value.trim();
                        if (!name || busy) return;
                        if (Array.from(names.options).some(function(item) { return item.value === name; }) &&
                            !window.confirm(_('Заменить существующий пресет?'))) return;
                        send('save', name, '', selection.value);
                    })
                ]), notice
            ])
        };
    },

    comparison: function(followJob) {
        var root = E('div');
        var profiles = E('select', {class:'cbi-input-select',multiple:'',size:7});
        var lists = E('select', {class:'cbi-input-select',multiple:'',size:5});
        var mode = E('select', {class:'cbi-input-select'}, ['tls13','tls12','http','quic'].map(function(item) { return option(item); }));
        var repeats = number(2,1,5), limit = number(20,1,100), timeout = number(5,2,30);
        var status = E('p', {role:'status'}), notice = E('p', {role:'status'});
        var report = E('div'), schedule = E('div');
        var running = false, busy = false, available = false, loaded = false;
        var nextStatus = 0;
        var start = button(_('Начать сравнение'), function() {
            var selected = chosen(profiles);
            if (!selected) {
                notice.textContent = _('Выберите стратегии для сравнения.');
                return;
            }
            if (![repeats,limit,timeout].every(function(input) { return input.reportValidity(); })) return;
            submit(['compare-start',selected,chosen(lists) || 'all',mode.value,repeats.value,limit.value,timeout.value,'get'].join(':'));
        });
        var stop = button(_('Остановить сравнение'), function() { submit('compare-stop'); });

        function controls() {
            start.disabled = busy || running || !available;
            stop.disabled = busy || !running;
        }

        function submit(action, after) {
            if (busy) return;
            busy = true;
            controls();
            notice.textContent = _('Ставим действие в очередь…');
            constructorAction('zapret2', action).then(assertResult).then(function(result) {
                if (!result.job) throw new Error(_('Задание недоступно'));
                followJob(result.job, function(final) {
                    busy = false;
                    controls();
                    notice.textContent = final.phase === 'done' ? _('Действие выполнено') : _('Действие завершилось с ошибкой');
                    if (final.phase !== 'done') jobOutput(result.job).then(function(details) {
                        notice.textContent = details.output || notice.textContent;
                    }).catch(function() {});
                    refresh();
                    if (after) after();
                });
            }).catch(function(error) { busy = false; controls(); notice.textContent = error.message; });
        }

        function refresh() {
            nextStatus = Date.now() + (running ? 4000 : 15000);
            return constructorInfo('compare-status').then(assertResult).then(function(data) {
                running = !!data.running;
                if (!data.available) {
                    status.textContent = _('Для сравнения нужен комплект strategy-check.');
                    return;
                }
                status.textContent = [data.state, data.progress].filter(Boolean).join(' · ') || _('Сравнение не запускалось');
                var scores = (data.scores || []).slice().sort(function(a, b) {
                    if (a.id === 'baseline') return -1;
                    if (b.id === 'baseline') return 1;
                    return Number(b.pass) / (Number(b.tested) || 1) - Number(a.pass) / (Number(a.tested) || 1);
                });
                report.replaceChildren(
                    table([_('Стратегия'),_('Успешно'),_('Проверено')], scores.map(function(item) {
                        return [item.id === 'baseline' ? _('Контрольный прогон') : item.id,item.pass,item.tested];
                    })),
                    data.log ? E('details', {}, [E('summary', {}, _('Журнал')),E('pre', {class:'ows-job-output'}, data.log)]) : '',
                    E('details', {}, [E('summary', {}, _('История')),table([_('Начало'),_('Режим'),_('Состояние')],
                        (data.history || []).map(function(item) { return [timestamp(item.started),item.mode,item.state]; }))])
                );
            }).catch(function(error) { status.textContent = error.message; }).finally(controls);
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
                        button(_('Обновить журнал проверок'),loadSchedule)
                    ]),
                    data.log ? E('pre', {class:'ows-job-output'}, data.log) : ''
                );
            }).catch(function(error) { schedule.textContent = error.message; });
        }

        function load() {
            if (loaded) return refresh();
            loaded = true;
            controls();
            return Promise.all([refresh(),loadSchedule(),constructorInfo('compare-catalog').then(assertResult).then(function(data) {
                available = !!data.available;
                profiles.replaceChildren.apply(profiles, (data.profiles || []).map(function(item) {
                    var node = option(item.id); node.selected = item.enabled; return node;
                }));
                lists.replaceChildren.apply(lists, (data.lists || []).map(function(item) { return option(item); }));
            }).catch(function(error) { notice.textContent = error.message; }).finally(controls)]);
        }

        root.replaceChildren(
            E('div', {class:'ows-fields'}, [
                field(_('Стратегии'),profiles),field(_('Списки (пусто — все)'),lists),field(_('Протокол'),mode),
                field(_('Повторы'),repeats),field(_('Доменов на список'),limit),field(_('Тайм-аут, с'),timeout)
            ]),
            E('div', {class:'ows-actions'}, [start,stop,button(_('Обновить результаты'),refresh)]),
            status,notice,report,E('h4', {}, _('Расписание проверок')),schedule
        );
        poll.add(function() {
            if (loaded && document.contains(root) && !root.closest('[hidden]') && Date.now() >= nextStatus) return refresh();
        }, 4);
        return {id:'zapret2-comparison',label:_('Сравнение стратегий'),content:root,activate:load};
    }
});
