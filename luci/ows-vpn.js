'use strict';
'require baseclass';
'require rpc';
'require view.ows-vpn-editor as editor';
'require view.ows-native as nativeView';

var info = rpc.declare({ object: 'ows', method: 'vpn_state', params: ['id'] });
var execute = rpc.declare({ object: 'ows', method: 'vpn_action', params: ['id', 'action', 'target'] });
var output = rpc.declare({ object: 'ows', method: 'job_output', params: ['job'] });
var edit = rpc.declare({ object: 'ows', method: 'vpn_edit', params: ['id', 'change'] });
var subscriptionUrl = rpc.declare({ object: 'ows', method: 'vpn_subscription_url', params: ['id'] });
return baseclass.extend({
    supports: function(entry, drivers) {
        return Object.prototype.hasOwnProperty.call(drivers, entry.id) && drivers[entry.id] === entry.service;
    },
    tab: function(entry, createTabs, follow, template) {
        template = template || {};
        var status = E('div');
        var subscriptions = E('div');
        var outputs = E('div');
        var routes = E('div');
        var plugins = E('div');
        var migration = E('div');
        var listActions = E('div');
        var draftActions = E('div');
        var tabsHost = E('div', {}, E('p', {}, _('Загрузка состояния…')));
        var currentLayout = '';
        var prefix = 'vpn-' + entry.id + '-';
        var sectionTabs, pendingSection;
        var configEditor = editor.init(entry, follow, {outputs:outputs, routes:routes, listActions:listActions});
        var notice = E('p', { 'aria-live': 'polite' });
        var log = E('pre', { hidden: '', class: 'ows-job-output' });
        var refresh = E('button', { type: 'button', class: 'cbi-button' }, _('Обновить'));
        var busy = false;

        function submit(action, target, change, onResult) {
            if (busy) return;
            if (action === 'takeover' && !window.confirm(_('Передать управление этим модулем в OWS?'))) return;
            busy = true;
            notice.textContent = _('Ставим проверку в очередь');
            log.hidden = true;
            var request = change ? edit(entry.id, JSON.stringify(change)) : execute(entry.id, action, target || '');
            request.then(function(result) {
                if (!result.job) {
                    busy = false;
                    notice.textContent = result.error || _('Проверка недоступна');
                    if (onResult) onResult({output:notice.textContent}, 'operation_failed');
                    return;
                }
                notice.textContent = _('Проверка в очереди');
                follow(result.job, function(result) {
                    notice.textContent = result.phase === 'done' ? _('Проверка завершена') : _('Проверка не пройдена');
                    output(result.job).then(function(detail) {
                        log.textContent = detail.output || '';
                        log.hidden = !log.textContent;
                        if (onResult) onResult(detail, result.phase);
                    }, function() {
                        notice.textContent = _('Не удалось прочитать журнал задания');
                        if (onResult) onResult({output:notice.textContent}, 'operation_failed');
                    }).finally(function() { busy = false; });
                    if ((change && result.phase === 'done') || ['setup', 'prepare_migration', 'check_handover', 'refresh_draft_subscription',
                        'refresh_live_subscription', 'refresh_live_lists', 'test_draft_lists', 'takeover', 'apply_draft'].indexOf(action) >= 0) {
                        configEditor.refresh();
                        load();
                    }
                });
            }, function() {
                busy = false;
                notice.textContent = _('Запрос проверки отклонён');
                if (onResult) onResult({output:notice.textContent}, 'operation_failed');
            });
        }

        function button(label, action, enabled, target) {
            var node = E('button', { type: 'button', class: 'cbi-button' }, label);
            node.disabled = !enabled;
            node.addEventListener('click', function() { submit(action, target); });
            return node;
        }

        function draftPanel(editable, outputName) {
            draftActions.replaceChildren();
            if (!editable) return;
            var summary = E('div', {'aria-live':'polite'});
            var apply = E('button', {type:'button', class:'cbi-button cbi-button-action'}, _('Применить манифест'));
            apply.disabled = true;
            var checkedRevision;
            var preview = E('button', {type:'button', class:'cbi-button'}, _('Проверить изменения'));
            preview.addEventListener('click', function() {
                if (busy) return;
                preview.disabled = true;
                apply.disabled = true;
                summary.textContent = _('Читаем текущую версию…');
                info(entry.id).then(function(current) {
                    if (!current.draft_apply || !current.draft_apply.revision)
                        throw new Error(_('Применение манифеста недоступно.'));
                    submit('preview_draft', current.draft_apply.revision, null, function(detail, phase) {
                        var report = detail.result;
                        if (phase !== 'done' || !report || report.kind !== 'draft_preview') {
                            summary.textContent = detail.output || _('Манифест не прошёл проверку.');
                            return;
                        }
                        var labels = {lists:_('списки'), rules:_('правила'), outputs:_('выходы'),
                            lan:_('LAN'), dns:_('DNS'), clients:_('устройства')};
                        checkedRevision = report.revision;
                        apply.disabled = !report.changes.length;
                        summary.textContent = report.changes.length ?
                            _('Изменятся разделы') + ' · ' + report.changes.map(function(section) {
                                return labels[section] || section;
                            }).join(', ') : _('Рабочая конфигурация совпадает с настроенным манифестом.');
                        if (Array.isArray(report.node_changes) && report.node_changes.length)
                            summary.appendChild(E('ul', {}, report.node_changes.map(function(change) {
                                return E('li', {}, outputName(change.id) + ' · ' + editor.configuredNodesLabel(change.before) +
                                    ' → ' + editor.configuredNodesLabel(change.after));
                            })));
                    });
                }).catch(function(error) {
                    summary.textContent = error.message || _('Не удалось прочитать состояние.');
                }).finally(function() { preview.disabled = false; });
            });
            apply.addEventListener('click', function() {
                if (busy || !checkedRevision || !window.confirm(_('Применить проверенный манифест?'))) return;
                apply.disabled = true;
                submit('apply_draft', checkedRevision, null);
            });
            draftActions.replaceChildren(E('div', {class:'ows-actions'}, [preview, apply]), summary);
        }

        function subscriptionForm(config) {
            if (!config.editable) return E('p', {}, _('Редактирование ссылки недоступно.'));
            var input = E('input', {
                type:'password', class:'cbi-input-text', placeholder:'https://…', maxlength:'4096',
                autocomplete:'new-password', spellcheck:'false'
            });
            var reset = E('input', {type:'checkbox'});
            var remove = E('button', {type:'button', class:'cbi-button'}, _('Удалить ссылку'));
            remove.disabled = !config.configured;
            remove.addEventListener('click', function() {
                if (!config.configured || busy) return;
                if (window.confirm(_('Удалить ссылку и остановить обновления? Последний список узлов сохранится.')))
                    submit('subscription_remove', null, {type:'subscription_remove', revision:config.revision});
            });
            var current = E('input', {type:'text', class:'cbi-input-text', readonly:'readonly', spellcheck:'false'});
            var currentField = E('label', {class:'ows-field', hidden:''}, [
                E('span', {}, _('Текущая ссылка')), current
            ]);
            var reveal = E('button', {type:'button', class:'cbi-button', 'aria-expanded':'false'}, _('Показать текущую ссылку'));
            reveal.hidden = !config.configured;
            reveal.addEventListener('click', function() {
                if (!currentField.hidden) {
                    current.value = '';
                    currentField.hidden = true;
                    reveal.textContent = _('Показать текущую ссылку');
                    reveal.setAttribute('aria-expanded', 'false');
                    return;
                }
                reveal.disabled = true;
                subscriptionUrl(entry.id).then(function(result) {
                    if (!result.url) {
                        notice.textContent = result.error || _('Ссылка недоступна.');
                        return;
                    }
                    current.value = result.url;
                    currentField.hidden = false;
                    reveal.textContent = _('Скрыть ссылку');
                    reveal.setAttribute('aria-expanded', 'true');
                }, function() {
                    notice.textContent = _('Не удалось прочитать ссылку подписки.');
                }).finally(function() { reveal.disabled = false; });
            });
            var form = E('form', {}, [
                E('p', {}, config.configured ? (config.host ? _('Источник подписки') + ' · ' + config.host :
                    _('HTTPS-ссылка настроена.')) : _('HTTPS-ссылка не задана.')),
                E('div', {class:'ows-actions'}, [reveal]),
                currentField,
                E('p', {}, config.live ? _('Изменения применяются к рабочей подписке и расписанию.') :
                    _('Изменения записываются в манифест.')),
                E('label', {class:'ows-field'}, [E('span', {}, _('Ссылка подписки')), input]),
                config.can_reset_pins ? E('label', {}, [reset, ' ',
                    _('Разрешить автоматический выбор, если закреплённого узла нет в новой подписке')]) : '',
                E('div', {class:'ows-actions'}, [
                    E('button', {type:'submit', class:'cbi-button cbi-button-action'},
                        config.configured ? _('Заменить ссылку') : _('Добавить подписку')),
                    button(_('Обновить сейчас'), config.live ? 'refresh_live_subscription' : 'refresh_draft_subscription', config.configured),
                    remove
                ])
            ]);
            form.addEventListener('submit', function(event) {
                event.preventDefault();
                var url = input.value.trim();
                if (!/^https:\/\/[^/?#\s]+/.test(url)) {
                    notice.textContent = _('Введите HTTPS-ссылку подписки.');
                    input.focus();
                    return;
                }
                submit('subscription_set', null, {type:'subscription_set', revision:config.revision,
                    url:url, reset_pins:reset.checked});
            });
            return form;
        }

        function table(columns, rows, empty) {
            if (!rows.length) return E('p', {}, empty);
            return E('table', { class: 'table' }, [
                E('thead', {}, E('tr', { class: 'tr table-titles' }, columns.map(function(title) {
                    return E('th', { class: 'th', scope: 'col' }, title);
                }))),
                E('tbody', {}, rows.map(function(cells) {
                    return E('tr', { class: 'tr' }, cells.map(function(cell) { return E('td', { class: 'td' }, cell); }));
                }))
            ]);
        }

        function statusDetails(data, outputName) {
            var rules = data.routes || [];
            var search = E('input', {type:'search', class:'cbi-input-text', placeholder:'OpenAI, cloudfront, VPN'});
            var results = E('div', {class:'ows-service-table'});

            function filtered(rows, query) {
                return rows.filter(function(row) {
                    return !query || row.join(' ').toLowerCase().includes(query);
                });
            }
            function count(label, number) {
                return number ? label + ' · ' + number : '';
            }
            function renderDetails() {
                var query = search.value.trim().toLowerCase();
                var lists = (data.working_lists || []).map(function(item) {
                    var sources = [
                        count(_('Домены'), item.domains), count(_('Файлы доменов'), item.domain_files),
                        count(_('Подсети'), item.prefixes), count(_('Файлы подсетей'), item.prefix_files),
                        count('SRS', item.srs)
                    ].filter(Boolean);
                    var references = rules.filter(function(rule) { return (rule.list_ids || []).includes(item.id); })
                        .map(function(rule) { return rule.id; });
                    return [item.id, sources.join(', ') || '—', references.join(', ') || '—'];
                });
                var ruleRows = rules.map(function(rule) {
                    return [rule.id, rule.match || '—', outputName(rule.output),
                        rule.dns || '—', rule.enabled === false ? _('Выключено') : _('Включено')];
                });
                var channelRows = (data.channels || []).map(function(channel) {
                    var type = channel.kind === 'domains' ? _('Домены') :
                        (channel.kind === 'prefixes' ? _('Подсети') : channel.kind);
                    return [channel.id, type || '—', outputName(channel.output),
                        (channel.rules || []).join(', ') || '—',
                        channel.live ? _('Активен') : _('Неактивен'), String(channel.packets)];
                });
                var empty = query ? _('По этому запросу совпадений нет.') : _('Нет данных.');
                results.replaceChildren(
                    E('h5', {}, _('Списки')),
                    E('p', {}, _('Список хранит назначения для правил. Ищите по имени списка или сервиса.')),
                    table([_('Список'), _('Содержимое'), _('Используется в правилах')], filtered(lists, query), empty),
                    E('h5', {}, _('Правила')),
                    E('p', {}, _('Правило связывает список или условие с выходом и DNS.')),
                    table([_('Правило'), _('Назначение'), _('Выход'), _('DNS'), _('Состояние')], filtered(ruleRows, query), empty),
                    E('h5', {}, _('Каналы')),
                    E('p', {}, _('Демон может объединять несколько правил в одном рабочем канале.')),
                    table([_('Канал'), _('Тип'), _('Выход'), _('Правила в канале'), _('Состояние'), _('Пакеты')],
                        filtered(channelRows, query), empty)
                );
            }

            search.addEventListener('input', renderDetails);
            renderDetails();
            return E('details', {class:'ows-section'}, [
                E('summary', {}, _('Подробнее о списках, правилах и каналах')),
                E('label', {class:'ows-field'}, [E('span', {}, _('Поиск по спискам, правилам и каналам')), search]),
                results
            ]);
        }

        function statusPanel(data, outputName, canDiagnose) {
            if (template.renderStatus) return template.renderStatus(data, { outputName: outputName,
                canDiagnose: canDiagnose, button: button });
            var runtime = data.runtime || {};
            var summary = data.summary || {};
            var kinds = summary.list_kinds || {};
            var configured = runtime.configured_interfaces || [];
            var active = runtime.interfaces || [];
            var dns = data.dns_sources || [];

            function card(title, content) {
                return E('div', {class:'ows-vpn-metric'}, [E('h5', {}, title)].concat(content));
            }
            function value(label, count) {
                return E('li', {}, [label, ' · ', E('strong', {}, count == null ? '—' : String(count))]);
            }
            function names(items) { return items.length ? items.join(', ') : _('Нет'); }
            function dnsRows() {
                return dns.map(function(source) {
                    var endpoint = source.endpoint;
                    var via = source.output ? ' · ' + outputName(source.output) : '';
                    if (endpoint && endpoint.host) {
                        var protocol = endpoint.scheme === 'https' ? 'DoH' : endpoint.scheme.toUpperCase();
                        return E('li', {}, [E('code', {}, endpoint.host), ' · ' + protocol + via]);
                    }
                    if (source.members.length) {
                        var strategy = source.strategy === 'failover' ? _('переключение при отказе') : source.strategy;
                        return E('li', {}, _('Группа DNS') + (strategy ? ' · ' + strategy : '') + ' · ' +
                            _('источников') + ' ' + source.members.length + via);
                    }
                    return E('li', {}, source.id + via);
                });
            }

            return [
                E('div', {class:'ows-module-heading'}, [
                    E('h4', {}, _('Состояние') + ' ' + entry.name),
                    canDiagnose ? button(_('Запустить диагностику'), 'diagnose', true) : ''
                ]),
                E('p', {}, [
                    data.installed ? _('Ядро') + ' ' + (data.version || '—') : _('Движок не установлен'),
                    ' · ', data.running ? _('Демон запущен') : _('Демон не запущен'),
                    runtime.available ? '' : ' · ' + _('Данные демона недоступны')
                ]),
                E('div', {class:'ows-fields'}, [
                    card(_('Интерфейсы LAN'), [
                        E('p', {}, [_('В конфигурации'), ' · ', E('strong', {}, names(configured))]),
                        E('p', {}, [_('В работе'), ' · ', runtime.available ? names(active) : _('Нет данных')])
                    ]),
                    card(_('Списки'), [
                        E('ul', {}, [value(_('Всего списков'), summary.lists), value(_('С доменами'), kinds.domains),
                            value(_('С подсетями'), kinds.prefixes), value(_('С наборами SRS'), kinds.srs)])
                    ]),
                    card(_('DNS upstream'), [
                        dns.length ? E('ul', {}, dnsRows()) : E('p', {}, _('Источники DNS не указаны.'))
                    ]),
                    card(_('Правила и каналы'), [
                        E('p', {}, [_('Правил включено'), ' · ', E('strong', {},
                            summary.rules_enabled == null ? '—' : summary.rules_enabled + ' / ' + summary.routes)]),
                        E('p', {}, [_('Активных каналов'), ' · ', E('strong', {},
                            summary.channels_live == null ? _('Нет данных') : summary.channels_live + ' / ' + summary.channels)])
                    ])
                ]),
                statusDetails(data, outputName)
            ];
        }

        function render(data) {
            var entries = data.outputs || [];
            function outputName(id) {
                var item = entries.find(function(entry) { return entry.id === id; });
                return item ? item.label || id : id || '—';
            }
            var abilities = data.capabilities || {};
            var ui = data.ui || {};
            var hasSubscription = !!data.subscription || entries.some(function(item) { return item.subscription; });
            var handover = data.handover || {};
            var native = template.native;
            var showNative = !!(native && (!native.visible || native.visible(data)));
            mountTabs(ui, abilities, hasSubscription, !!handover.ownership_transferred, showNative, data);
            status.replaceChildren.apply(status, statusPanel(data, outputName, abilities.diagnose));
            if (abilities.setup) status.appendChild(button(_('Подготовить чистые настройки'), 'setup', true));
            if (data.standalone_draft && !data.configured)
                status.appendChild(E('p', {}, _('Чтобы запустить маршрутизацию, добавьте сервис, проверьте изменения и нажмите «Применить манифест».')));
            draftPanel(!!data.draft_apply, outputName);
            listActions.replaceChildren((abilities.refresh_live_lists || (abilities.refresh_live && handover.ownership_transferred)) ?
                button(_('Обновить рабочие списки'), 'refresh_live_lists', true) : '');
            if (hasSubscription) subscriptions.replaceChildren(
                E('h4', {}, _('Подписка')),
                data.subscription ? subscriptionForm(data.subscription) : '',
                E('p', {}, data.previous_manager ?
                    _('Обновлением подписки управляет прежняя панель') + ' · ' + data.previous_manager :
                    _('Проверка разбирает локальный список узлов и показывает результат парсера.')),
                table([_('Выход'), _('Протокол'), _('Применённый выбор'), _('Узел в работе'), _('Проверка списка')], entries.filter(function(item) {
                    return item.subscription;
                }).map(function(item) {
                    return [outputName(item.id), item.protocol || '—',
                        editor.configuredNodesLabel(item.configured_nodes), editor.activeNodesLabel(item.active_nodes, item, data),
                        button(_('Проверить узлы'), 'inspect_subscription', abilities.inspect_subscriptions && item.can_check, item.id)];
                }), _('Подписки в конфигурации не найдены'))
            );
            outputs.replaceChildren(table([_('Выход'), _('Тип'), _('Протокол'), _('Интерфейс'), _('Состояние'), _('Выбранный выход')],
                entries.map(function(item) {
                return [outputName(item.id), item.kind || '—', item.protocol || '—', item.device || '—',
                    item.runtime ? (item.up ? _('Работает') : _('Неактивен')) : '—', outputName(item.selected)];
            }), _('Выходы в конфигурации не найдены')));
            routes.replaceChildren(
                E('h4', {}, _('Настроенные правила')),
                table([_('Правило'), _('Выход'), _('Список или условие'), _('DNS')], (data.routes || []).map(function(item) {
                    return [item.id, outputName(item.output), item.match || '—', item.dns || '—'];
                }), _('Правила не найдены')),
                E('h4', {}, _('Каналы демона')),
                table([_('Канал'), _('Выход'), _('Состояние'), _('Пакеты'), _('Байты')], (data.channels || []).map(function(item) {
                    return [item.id, outputName(item.output), item.live ? _('Активен') : _('Неактивен'), String(item.packets), String(item.bytes)];
                }), _('Каналы не найдены'))
            );
            if (ui.plugins) {
                var loaded = data.plugins || [];
                plugins.replaceChildren(E('details', {class:'ows-section'}, [
                    E('summary', {}, _('Плагины') + ' · ' + loaded.length),
                    table([_('Плагин'), _('Версия'), _('Состояние')], loaded.map(function(item) {
                        return [item.id, item.version || '—', item.state || '—'];
                    }), _('Демон не сообщил о плагинах'))
                ]));
            }
            if (ui.migration && !handover.ownership_transferred) renderMigration(data, abilities);
        }

        function renderMigration(data, abilities) {
            var draft = data.migration || {};
            var handover = data.handover || {};
            var check = handover.preflight;
            var subscription = handover.subscription;
            var lists = handover.lists;
            migration.replaceChildren(
                E('p', {}, draft.validated ? _('Манифест переноса проверен ядром') : _('Манифест переноса ещё не проверен')),
                draft.prepared ? E('dl', {}, [
                    E('dt', {}, _('Манифест переноса')), E('dd', {}, draft.draft),
                    E('dt', {}, _('Скопировано файлов')), E('dd', {}, String(draft.files)),
                    E('dt', {}, _('Фоновые задания прежней панели')), E('dd', {}, String(draft.legacy_jobs))
                ]) : E('p', {}, _('Импорт создаёт манифест переноса из текущей конфигурации.')),
                E('h4', {}, _('Передача управления')),
                check ? E('ul', {}, [
                    E('li', {}, handover.recheck ? _('Манифест изменился. Повторите проверку.') : _('Манифест прошёл последнюю проверку.')),
                    E('li', {}, check.source_match ? _('Рабочие файлы совпали со снимком импорта.') : _('Рабочие файлы изменились после импорта.')),
                    E('li', {}, check.same_rules ? _('Скомпилированные правила совпали.') : _('Правила в манифесте отличаются от рабочих.')),
                    E('li', {}, _('Активные задания прежней панели') + ' · ' + check.legacy_jobs)
                ]) : E('p', {}, _('Проверка готовности ещё не запускалась')),
                E('p', {}, subscription ?
                    _('Подписка в манифесте проверена. Выходов') + ' · ' + subscription.outputs :
                    _('Подписка в манифесте ещё не обновлялась')),
                E('p', {}, lists ? _('Источники списков проверены') + ' · ' + lists.files :
                    _('Обновление списков ещё не проверено')),
                E('p', {}, handover.ownership_transferred ?
                    _('Рабочим модулем и его расписанием управляет OWS.') :
                    _('Перед переключением проверьте обновление подписки и списков.')),
                E('div', {class:'ows-actions'}, handover.ownership_transferred ? [
                    button(_('Обновить рабочие списки'), 'refresh_live_lists', abilities.refresh_live),
                    button(_('Обновить рабочую подписку'), 'refresh_live_subscription', abilities.refresh_live)
                ] : [
                    button(_('Пересобрать манифест переноса'), 'prepare_migration', abilities.prepare_migration),
                    button(_('Обновить подписку в манифесте'), 'refresh_draft_subscription', abilities.refresh_draft_subscription),
                    button(_('Проверить обновление списков'), 'test_draft_lists', abilities.test_draft_lists),
                    button(_('Проверить готовность к передаче'), 'check_handover', abilities.check_handover),
                    button(_('Передать управление OWS'), 'takeover', abilities.takeover)
                ])
            );
        }

        function mountTabs(ui, abilities, hasSubscription, migrated, showNative, liveState) {
            configEditor.configure(ui, abilities, liveState);
            var migrationVisible = ui.migration === true && !migrated;
            var layout = JSON.stringify([ui.editor || [], ui.plugins === true, migrationVisible, ui.write_mode, hasSubscription, showNative]);
            if (currentLayout === layout) return;
            currentLayout = layout;
            var sections = [{
                id: prefix + 'status', label: hasSubscription ? _('Состояние и подписки') : _('Состояние'),
                content: E('div', {}, [hasSubscription ? subscriptions : '', status, ui.plugins ? plugins : ''])
            }].concat(configEditor.tabs());
            if (showNative) sections.push(nativeView.tab(Object.assign({}, template.native, { id: prefix + 'native' })));
            if (migrationVisible) sections.push({id: prefix + 'migration', label: _('Перенос'), content: migration});
            sectionTabs = createTabs(_('Разделы VPN'), sections, pendingSection);
            pendingSection = null;
            tabsHost.replaceChildren(sectionTabs.content);
        }

        function load() {
            refresh.disabled = true;
            return info(entry.id).then(function(data) {
                if (data.error) notice.textContent = data.error;
                else if (data.schema !== 1) notice.textContent = _('Версия шаблона VPN не поддерживается');
                else render(data);
            }, function() {
                notice.textContent = _('Не удалось прочитать состояние VPN');
            }).finally(function() { refresh.disabled = false; });
        }

        refresh.addEventListener('click', load);
        return {
            id: 'module-' + entry.id, label: entry.name, activate: load,
            openSection: function(section) {
                var id = prefix + section;
                if (sectionTabs) sectionTabs.selectId(id);
                else pendingSection = id;
            },
            content: [E('div', { class: 'ows-module-heading' }, [E('h3', {}, entry.name), refresh]),
                draftActions, tabsHost, notice, log, configEditor.feedback]
        };
    }
});
