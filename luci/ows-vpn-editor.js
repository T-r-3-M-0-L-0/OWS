'use strict';
'require baseclass';
'require rpc';
'require view.ows-ui as owsUI';

var field = owsUI.field, button = owsUI.button;

var read = rpc.declare({ object: 'ows', method: 'vpn_editor', params: ['id'] });
var readNodes = rpc.declare({ object: 'ows', method: 'vpn_nodes', params: ['id', 'target'] });
var edit = rpc.declare({ object: 'ows', method: 'vpn_edit', params: ['id', 'change'] });
var action = rpc.declare({ object: 'ows', method: 'vpn_action', params: ['id', 'action', 'target'] });
var output = rpc.declare({ object: 'ows', method: 'job_output', params: ['job'] });
var listPage = rpc.declare({ object: 'ows', method: 'vpn_list_page', params: ['job', 'kind', 'page', 'search'] });

function dropdown(options, initial) {
    var select = E('select', { class: 'cbi-input-select' }, options.map(function(item) {
        return E('option', { value: item[0] }, item[1]);
    }));
    if (initial != null) select.value = String(initial);
    return select;
}

function numeric(label, value) {
    var input = E('input', { class: 'cbi-input-text', type: 'number', min: '0', max: '86400', value: value });
    return [field(label, input), input];
}

function outputOption(item) {
    return [item.id, item.label || item.id];
}

function subsection(title, content) {
    return E('details', {class:'ows-section'}, [E('summary', {}, title), content]);
}

return baseclass.extend({
    init: function(entry, follow, runtime) {
        var panels = {
            connections:E('div'), services:E('div'), devices:E('div'),
            exclusions:E('div'), settings:E('div')
        };
        var notice = E('p', { 'aria-live': 'polite' });
        var log = E('pre', { hidden: '', class: 'ows-job-output' });
        var snapshot = null;
        var catalogQuery = '';
        var pending = null;
        var busy = false;
        var sections = [];
        var capabilities = {};
        var writeMode = 'draft';
        var measurements = Object.create(null);
        var batches = Object.create(null);

        function submit(changes, operation, target, onResult) {
            if (!snapshot || busy) return;
            busy = true;
            log.hidden = true;
            notice.textContent = _('Ставим задание в очередь');
            var promise = operation ? action(entry.id, operation, target) :
                edit(entry.id, JSON.stringify(Object.assign({revision: snapshot.revision}, changes)));
            promise.then(function(result) {
                if (!result.job) {
                    busy = false;
                    notice.textContent = result.error || _('Операция недоступна');
                    if (onResult) onResult({});
                    return;
                }
                notice.textContent = _('Задание в очереди');
                follow(result.job, function(finalState) {
                    notice.textContent = finalState.phase === 'done' ? (operation ? _('Задание завершено') :
                        (writeMode === 'live' ? _('Изменение применено') : _('Изменение сохранено в черновике'))) :
                        _('Задание не прошло проверку');
                    output(finalState.job).then(function(detail) {
                        log.textContent = detail.output || '';
                        log.hidden = !log.textContent;
                        if (onResult) onResult(detail, finalState.job);
                    }, function() {
                        notice.textContent = _('Ошибка чтения журнала');
                        if (onResult) onResult({});
                    }).finally(function() { busy = false; });
                    if (!operation) load(true);
                });
            }, function() {
                busy = false;
                if (onResult) onResult({});
                notice.textContent = _('Запрос отклонён');
            });
            return true;
        }

        function save(callback, disabled) {
            return button(saveLabel(), function() { submit(callback()); }, disabled);
        }

        function saveLabel() { return writeMode === 'live' ? _('Применить') : _('Сохранить в черновик'); }

        function actions(elements) { return E('div', { class: 'ows-actions' }, elements); }
        function fields(elements) { return E('div', { class: 'ows-fields' }, elements); }

        function renderConnections(data) {
            var route = dropdown([['vpn','VPN'], ['tunnel',_('Туннель')], ['warp','WARP']]);
            var dest = dropdown([]);
            var use = save(function() { return {type:'connection', output:dest.value}; }, true);
            function targets() {
                var filtered = data.outputs.filter(function(item) { return item.route === route.value; });
                dest.replaceChildren.apply(dest, filtered.map(function(item) {
                    return E('option', {value:item.id}, item.label || item.id);
                }));
                use.disabled = !filtered.length;
            }
            route.addEventListener('change', targets);
            targets();
            var source = dropdown(data.outputs.filter(function(item) { return item.subscription; }).map(outputOption));
            var table = E('div');
            var selectedNode = null;
            var nodeRows = [];
            var summary = E('p', {'aria-live':'polite'});
            var nodePage = 1;
            var nodeRequest = 0;
            var pageInfo = E('span', {'aria-live':'polite'});
            var previousNodes = button(_('Назад'), function() { loadNodes(nodePage - 1); }, true);
            var nextNodes = button(_('Дальше'), function() { loadNodes(nodePage + 1); }, true);
            function metricLabel(value) {
                if (value === null) return _('Измеряем…');
                if (!value) return '—';
                if (!value.ok) return _('Нет ответа');
                return Number.isFinite(value.handshake_ms) && value.handshake_ms >= 0 ?
                    String(value.handshake_ms) + ' ' + _('мс') : _('Ответил');
            }
            function renderNodes() {
                if (!nodeRows.length) {
                    table.replaceChildren(E('p', {}, _('Загрузите узлы выбранного выхода.')));
                    return;
                }
                var rows = nodeRows.map(function(node) {
                    var key = data.revision + ':' + source.value + ':' + node.index;
                    var select = E('input', {type:'radio', name:'ows-vpn-node-' + entry.id,
                        'aria-label':node.name || '#' + node.index});
                    select.checked = selectedNode === node.index;
                    select.addEventListener('change', function() { selectedNode = node.index; });
                    var value = measurements[key];
                    var state = value === null ? _('Проверяется') : value ? (value.ok ? _('Доступен') : _('Нет ответа')) : '—';
                    return E('tr', {class:'tr'}, [
                        select, node.name || '#' + node.index, state, value && value.ok ? metricLabel(value) : '—',
                        value && value.ok && Number.isFinite(value.ttfb_ms) && value.ttfb_ms > 0 ?
                            String(value.ttfb_ms) + ' ' + _('мс') : '—'
                    ].map(function(cell) { return E('td', {class:'td'}, cell); }));
                });
                table.replaceChildren(E('table', {class:'table'}, [
                    E('thead', {}, E('tr', {class:'tr table-titles'}, [
                        _('Выбор'), _('Узел'), _('Состояние'), _('Задержка'), _('Первый байт')
                    ].map(function(title) { return E('th', {class:'th',scope:'col'}, title); }))),
                    E('tbody', {}, rows)
                ]));
            }
            function readBatchPage(prefix, page) {
                var batch = batches[prefix];
                if (!batch) return;
                listPage(batch.job, 'nodes', page, '').then(function(response) {
                    if (batches[prefix] !== batch) return;
                    if (response.error) { notice.textContent = response.error; return; }
                    (response.entries || []).forEach(function(value) {
                        var key = prefix + value.index;
                        if (measurements[key] == null) measurements[key] = value;
                    });
                    renderNodes();
                }, function() { notice.textContent = _('Не удалось прочитать результаты опроса'); });
            }
            function showBatchSummary(prefix) {
                var batch = batches[prefix];
                summary.textContent = batch ? _('Доступно') + ' · ' + batch.working + ' / ' + batch.total : '';
            }
            function loadNodes(page) {
                var selected = source.value;
                var request = ++nodeRequest;
                if (!selected) return;
                previousNodes.disabled = nextNodes.disabled = true;
                return readNodes(entry.id, selected + ':' + page).then(function(result) {
                    if (request !== nodeRequest) return;
                    if (result.error) { notice.textContent = result.error; return; }
                    var current = data.outputs.find(function(item) { return item.id === selected; });
                    nodeRows = (page === 1 ? [{index:-1, name:_('Автоматически')}] : []).concat(result.nodes || []);
                    if (selectedNode == null) selectedNode = current && Number.isInteger(current.configured_nodes) ?
                        current.configured_nodes : -1;
                    nodePage = page;
                    var pages = Math.max(1, Math.ceil(result.total / 80));
                    pageInfo.textContent = pages > 1 ? page + ' / ' + pages : '';
                    previousNodes.disabled = page <= 1;
                    nextNodes.disabled = page >= pages;
                    var prefix = data.revision + ':' + selected + ':';
                    showBatchSummary(prefix);
                    renderNodes();
                    readBatchPage(prefix, page);
                }, function() { notice.textContent = _('Не удалось загрузить узлы'); });
            }
            var fetchNodes = button(_('Загрузить узлы'), function() { loadNodes(1); }, !source.options.length);
            source.addEventListener('change', function() {
                nodeRequest++;
                selectedNode = null;
                nodeRows = [];
                summary.textContent = '';
                pageInfo.textContent = '';
                previousNodes.disabled = nextNodes.disabled = true;
                loadNodes(1);
                renderNodes();
            });
            renderNodes();
            panels.connections.replaceChildren(
                E('h4', {}, _('Подключения')),
                sections.includes('connections') ? E('div', {}, [
                    E('h4', {}, _('Направление для сервисов')),
                    fields([field(_('Тип выхода'), route), field(_('Настроенный выход'), dest)]), actions([use])
                ]) : '',
                sections.includes('nodes') ? E('div', {}, [
                    E('h4', {}, _('Узлы подписки')),
                    fields([field(_('Подписка выхода'), source)]),
                    summary, table, actions([previousNodes, pageInfo, nextNodes]),
                actions([fetchNodes, button(_('Проверить выбранный узел'), function() {
                    if (selectedNode == null || selectedNode < 0) {
                        notice.textContent = _('Сначала выберите конкретный узел');
                        return;
                    }
                    var target = source.value + ':' + selectedNode;
                    var key = data.revision + ':' + target;
                    if (submit(null, 'probe_node', target, function(detail) {
                        measurements[key] = detail.probe || {ok:false};
                        renderNodes();
                    })) {
                        measurements[key] = null;
                        renderNodes();
                    }
                }, !capabilities.probe_node), button(_('Проверить все узлы'), function() {
                    if (!source.value) return;
                    var selected = source.value;
                    var prefix = data.revision + ':' + selected + ':';
                    if (!nodeRows.length) fetchNodes.click();
                    if (submit(null, 'probe_all_nodes', selected, function(detail, job) {
                        var report = detail.result;
                        Object.keys(measurements).forEach(function(key) {
                            if (key.startsWith(prefix) && measurements[key] === null) delete measurements[key];
                        });
                        if (report && report.kind === 'node_batch') {
                            batches[prefix] = {job:job, working:report.working, total:report.total};
                            if (source.value === selected) {
                                showBatchSummary(prefix);
                                readBatchPage(prefix, nodePage);
                            }
                        }
                        renderNodes();
                    })) {
                        delete batches[prefix];
                        Object.keys(measurements).forEach(function(key) {
                            if (key.startsWith(prefix)) delete measurements[key];
                        });
                        showBatchSummary(prefix);
                        nodeRows.forEach(function(node) {
                            if (node.index >= 0) measurements[prefix + node.index] = null;
                        });
                        renderNodes();
                    }
                }, !capabilities.probe_all_nodes), button(_('Сохранить узел'), function() {
                    if (selectedNode != null) submit({type:'node', output:source.value, node:selectedNode});
                    else notice.textContent = _('Сначала загрузите узлы');
                })])
                ]) : ''
            );
        }

        function renderServices(data) {
            var service = dropdown(data.services.map(function(item) { return [String(item.index), item.name]; }));
            var dest = dropdown(data.outputs.map(outputOption));
            var enabled = E('input', { type:'checkbox' });
            var domains = E('textarea', { class:'cbi-input-textarea', rows:5, placeholder:'example.org\n=www.example.net' });
            var name = E('input', {type:'text', maxlength:'100', class:'cbi-input-text'});
            var editMode = dropdown([['selected', _('Дополнить существующий сервис')], ['new', _('Создать свой сервис')]],
                data.services.length ? 'selected' : 'new');
            var upload = E('input', {type:'file', accept:'.txt,.lst,text/plain', hidden:''});
            var serviceStatus = E('p', {'aria-live':'polite'});

            function saveService(change) {
                if (new TextEncoder().encode(JSON.stringify(change)).length > 65000) {
                    serviceStatus.textContent = _('Список слишком большой. Общий размер запроса ограничен 64 КБ.');
                    return false;
                }
                if (!submit(change, null, null, function(detail) {
                    if (detail.output) serviceStatus.textContent = detail.output;
                })) {
                    serviceStatus.textContent = _('Дождитесь завершения текущего задания.');
                    return false;
                }
                serviceStatus.textContent = writeMode === 'live' ? _('Проверяем и применяем список…') :
                    _('Проверяем список и сохраняем черновик…');
                return true;
            }

            upload.addEventListener('change', function() {
                var file = upload.files[0];
                if (!file) return;
                upload.value = '';
                if (file.size > 64000) {
                    serviceStatus.textContent = _('Текстовый файл должен быть не больше 64 КБ.');
                    return;
                }
                file.text().then(function(content) {
                    domains.value = content;
                    if (editMode.value === 'new' && !name.value.trim())
                        name.value = file.name.replace(/\.[^.]+$/, '').slice(0, 100);
                    serviceStatus.textContent = _('Файл загружен. Проверьте список доменов перед сохранением.');
                }, function() { serviceStatus.textContent = _('Не удалось прочитать файл.'); });
            });
            function selectService() {
                var selected = data.services.find(function(item) { return String(item.index) === service.value; });
                if (!selected) return;
                enabled.checked = selected.enabled;
                dest.value = selected.output;
            }
            service.addEventListener('change', selectService);
            selectService();
            var catalog = data.catalog || [];
            var groups = Array.from(new Set(catalog.map(function(item) { return item.group; }))).sort();
            var category = dropdown([['', _('Все категории')]].concat(groups.map(function(group) { return [group, group]; })));
            var search = E('input', { type:'search', class:'cbi-input-text', value:catalogQuery,
                placeholder:_('Например, Telegram или YouTube') });
            var presetOutput = dropdown(data.outputs.map(outputOption));
            var catalogGrid = E('div', {class:'ows-service-table'});
            var assigned = new Map();
            data.services.forEach(function(rule) {
                [].concat(rule.match || []).forEach(function(id) { assigned.set(id, rule); });
            });
            var listPanel = E('div', {hidden:'', class:'ows-service-preview'});
            var inspectRule = button(_('Посмотреть текущие домены и подсети'), function() {
                inspect('rule:' + data.revision + ':' + service.value);
            }, !service.options.length || !capabilities.preview_service_lists);

            function inspect(target) {
                if (!submit(null, 'preview_service_lists', target, function(detail, job) {
                    var report = detail.result;
                    if (!report || report.kind !== 'list_preview') {
                        listPanel.replaceChildren(E('p', {}, _('Не удалось открыть состав списка.')));
                        return;
                    }
                    var kind = dropdown([['domains', _('Домены') + ' (' + report.domains + ')'],
                        ['prefixes', _('Подсети') + ' (' + report.prefixes + ')']], report.domains ? 'domains' : 'prefixes');
                    var page = 1;
                    var requestId = 0;
                    var query = '';
                    var searchLists = E('input', {type:'search', class:'cbi-input-text', maxlength:'128'});
                    var lines = E('pre', {class:'ows-job-output'});
                    var pageInfo = E('span', {'aria-live':'polite'});
                    var previous = button(_('Назад'), function() { page--; showPage(); });
                    var next = button(_('Дальше'), function() { page++; showPage(); });
                    function applySearch() {
                        query = searchLists.value.trim();
                        page = 1;
                        showPage();
                    }
                    searchLists.addEventListener('keydown', function(event) {
                        if (event.key === 'Enter') { event.preventDefault(); applySearch(); }
                    });
                    function showPage() {
                        var current = ++requestId;
                        previous.disabled = next.disabled = true;
                        lines.textContent = _('Загрузка…');
                        listPage(job, kind.value, page, query).then(function(result) {
                            if (current !== requestId) return;
                            lines.textContent = result.error || (result.entries || []).join('\n') || _('Записей нет.');
                            if (result.error) return;
                            var pages = Math.max(1, Math.ceil(result.total / 80));
                            previous.disabled = page <= 1;
                            next.disabled = page >= pages;
                            pageInfo.textContent = page + ' / ' + pages;
                        }, function() {
                            if (current === requestId) lines.textContent = _('Не удалось прочитать страницу списка.');
                        });
                    }
                    var download = button(_('Скачать весь список TXT'), function() {
                        var downloadKind = kind.value;
                        var pages = Math.ceil(report[downloadKind] / 80);
                        var chunks = [];
                        download.disabled = true;
                        function readNext(number) {
                            return listPage(job, downloadKind, number, '').then(function(result) {
                                if (result.error) throw new Error(result.error);
                                chunks.push(result.entries.join('\n') + '\n');
                                if (number < pages) return readNext(number + 1);
                            });
                        }
                        (pages ? readNext(1) : Promise.resolve()).then(function() {
                            var url = URL.createObjectURL(new Blob(chunks, {type:'text/plain;charset=utf-8'}));
                            var link = E('a', {href:url, download:(report.name || entry.id) + '-' + downloadKind + '.txt'});
                            document.body.appendChild(link);
                            link.click();
                            link.remove();
                            window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
                        }, function() {
                            serviceStatus.textContent = _('Не удалось скачать список. Откройте состав сервиса ещё раз.');
                        }).finally(function() { download.disabled = false; });
                    });
                    kind.addEventListener('change', function() { page = 1; showPage(); });
                    listPanel.replaceChildren(E('h4', {}, report.name || _('Состав списка')),
                        fields([field(_('Тип записей'), kind), field(_('Поиск в списке'), searchLists)]),
                        actions([button(_('Найти'), applySearch), download]),
                        report.unresolved ? E('p', {}, _('Наборов SRS, которые не удалось показать') + ' · ' + report.unresolved) : '',
                        lines, actions([previous, pageInfo, next]));
                    showPage();
                })) return;
                listPanel.hidden = false;
                listPanel.replaceChildren(E('p', {}, _('Загружаем состав сервиса…')));
                listPanel.scrollIntoView({block:'nearest'});
            }

            var catalogPage = 1;
            function filterCatalog() {
                catalogQuery = search.value;
                var phrase = catalogQuery.trim().toLowerCase();
                var matches = catalog.filter(function(item) {
                    return (!category.value || item.group === category.value) &&
                        [item.id, item.name, item.description].join(' ').toLowerCase().indexOf(phrase) >= 0;
                }).sort(function(a, b) { return a.name.localeCompare(b.name); });
                if (!matches.length) {
                    catalogGrid.replaceChildren(E('p', {}, _('Совпадений нет.')));
                    return;
                }
                var pages = Math.ceil(matches.length / 20);
                var serviceState = writeMode === 'live' ? _('Активен') : _('В черновике');
                var rows = matches.slice((catalogPage - 1) * 20, catalogPage * 20).map(function(item) {
                    var rule = assigned.get(item.id);
                    var active = !!(rule && rule.enabled);
                    var check = E('input', {type:'checkbox', 'aria-label':item.name + ' · ' + serviceState});
                    check.checked = active;
                    check.disabled = !rule && !presetOutput.options.length;
                    function update(value) {
                        if (rule) return saveService({type:'service', index:rule.index, output:rule.output, enabled:value});
                        return saveService({type:'catalog_service', id:item.id, output:presetOutput.value});
                    }
                    check.addEventListener('change', function() {
                        var requested = check.checked;
                        check.checked = active;
                        update(requested);
                    });
                    return E('tr', {class:'tr'}, [
                        E('td', {class:'td'}, check),
                        E('td', {class:'td'}, [E('strong', {}, item.name), E('div', {}, item.description || item.group)]),
                        E('td', {class:'td'}, [
                            button(_('Домены и подсети'), function() {
                                inspect(rule ? 'rule:' + data.revision + ':' + rule.index : 'catalog:' + item.id);
                            }, !capabilities.preview_service_lists),
                            button(_('Добавить список'), function() { update(true); }, active || !presetOutput.options.length)
                        ])
                    ]);
                });
                catalogGrid.replaceChildren(E('table', {class:'table'}, [
                    E('thead', {}, E('tr', {class:'tr table-titles'}, [
                        serviceState, _('Сервис'), _('Список')
                    ].map(function(title) { return E('th', {class:'th',scope:'col'}, title); }))),
                    E('tbody', {}, rows)
                ]), actions([
                    button(_('Назад'), function() { catalogPage--; filterCatalog(); }, catalogPage <= 1),
                    E('span', {}, catalogPage + ' / ' + pages + ' · ' + matches.length),
                    button(_('Дальше'), function() { catalogPage++; filterCatalog(); }, catalogPage >= pages)
                ]));
            }

            function resetCatalog() { catalogPage = 1; filterCatalog(); }
            search.addEventListener('input', resetCatalog);
            category.addEventListener('change', resetCatalog);
            filterCatalog();
            var existingFields = fields([field(_('Сервис'), service), E('label', {}, [enabled, ' ', _('Активен')])]);
            var nameField = field(_('Название'), name);
            function chooseEditMode() {
                existingFields.hidden = editMode.value === 'new';
                nameField.hidden = editMode.value !== 'new';
                inspectRule.hidden = editMode.value === 'new';
            }
            editMode.addEventListener('change', chooseEditMode);
            chooseEditMode();
            panels.services.replaceChildren(
                serviceStatus,
                catalog.length ? E('div', {}, [
                    E('h4', {}, _('Каталог сервисов')),
                    fields([field(_('Поиск'), search), field(_('Категория'), category), field(_('Выход для новых сервисов'), presetOutput)]),
                    catalogGrid
                ]) : '',
                listPanel,
                E('h4', {}, _('Свои домены')),
                fields([field(_('Действие'), editMode), field(_('Выход'), dest)]), existingFields, nameField,
                field(_('Домены, по одному на строку'), domains), upload,
                actions([button(_('Загрузить TXT или LST'), function() { upload.click(); }), inspectRule,
                    button(saveLabel(), function() {
                        if (editMode.value === 'new') {
                            if (!name.value.trim() || !domains.value.trim()) {
                                serviceStatus.textContent = _('Укажите название и хотя бы один домен.');
                                return;
                            }
                            saveService({type:'service_custom', name:name.value.trim(), output:dest.value, domains:domains.value});
                        } else {
                            if (!service.value) { serviceStatus.textContent = _('Выберите существующий сервис.'); return; }
                            saveService({type:'service', index:Number(service.value), output:dest.value,
                                enabled:enabled.checked, domains:domains.value.trim(), append:!!domains.value.trim()});
                        }
                    })])
            );
        }

        function renderDevices(data) {
            var policy = data.policy;
            var mode = dropdown([['all',_('Все устройства')],['allow',_('Только отмеченные')],['deny',_('Все, кроме отмеченных')]], policy.mode);
            var dest = dropdown(data.outputs.filter(function(item) { return item.route === 'vpn'; })
                .map(outputOption), policy.full_output || null);
            var devices = data.devices.slice();
            (policy.devices || []).concat(policy.full || []).forEach(function(mac) {
                if (!devices.some(function(item) { return item.mac === mac; })) devices.push({mac:mac});
            });
            var controls = devices.map(function(device) {
                return {device:device,
                    list:E('input',{type:'checkbox'}), full:E('input',{type:'checkbox'})};
            });
            var grid = E('table',{class:'table'}, [
                E('thead',{}, E('tr',{class:'tr table-titles'}, [_('Устройство'),_('MAC'),_('В списке'),_('Весь трафик через VPN')].map(function(title) {
                    return E('th',{class:'th',scope:'col'},title);
                }))),
                E('tbody',{},controls.map(function(row) {
                    row.list.checked = policy.devices.indexOf(row.device.mac) >= 0;
                    row.full.checked = policy.full.indexOf(row.device.mac) >= 0;
                    return E('tr',{class:'tr'},[row.device.name && row.device.name !== '-' ? row.device.name + ' · ' + row.device.address :
                        row.device.address || _('Офлайн'),row.device.mac,row.list,row.full].map(function(cell) {
                        return E('td',{class:'td'},cell);
                    }));
                }))
            ]);
            function toggleList() { controls.forEach(function(row) { row.list.disabled = mode.value === 'all'; }); }
            mode.addEventListener('change', toggleList);
            toggleList();
            panels.devices.replaceChildren(E('h4', {}, _('Политика устройств')),
                fields([field(_('Режим устройств'),mode),field(_('Выход для всего трафика'),dest)]),grid,
                actions([save(function() {
                    return {type:'devices', mode:mode.value, full_output:dest.value,
                        devices:controls.filter(function(row) { return row.list.checked; }).map(function(row) { return row.device.mac; }),
                        full:controls.filter(function(row) { return row.full.checked; }).map(function(row) { return row.device.mac; })};
                })]));
        }

        function renderExclusions(data) {
            var lines = E('textarea', {class:'cbi-input-textarea', rows:6, placeholder:'example.org\n=login.example.org\n192.0.2.0/24'});
            lines.value = data.policy.exclusions || '';
            panels.exclusions.replaceChildren(
                E('h4', {}, _('Исключения из VPN')),
                E('p', {}, _('Указанные назначения идут напрямую для всех устройств, включая отмеченные «Весь трафик через VPN».')),
                E('p', {}, [
                    _('Примеры: '), E('code', {}, 'example.org'), _(' — домен и его поддомены; '),
                    E('code', {}, '=login.example.org'), _(' — только точное имя; '),
                    E('code', {}, '192.0.2.0/24'), _(' — подсеть IPv4.')
                ]),
                field(_('Один домен, IPv4-адрес или подсеть на строку'), lines),
                E('p', {}, _('Сохранение пустого поля очищает этот список исключений.')),
                actions([save(function() { return {type:'exclusions', entries:lines.value}; })]));
        }

        function renderSettings(data) {
            var dest = dropdown(data.outputs.filter(function(item) { return ['vpn','warp','tunnel'].indexOf(item.route)>=0; })
                .map(outputOption));
            var fail = dropdown([['direct',_('Напрямую')],['drop',_('Блокировать')],['zapret','Zapret']]);
            var dns = dropdown([['fakeip','Fake IP'],['realip','Real IP']],data.dns.mode);
            var resolve = dropdown([['fakeip','Fake IP'],['realip','Real IP']]);
            var upstream = dropdown([['',_('Оставить как есть')]].concat(
                (data.dns.upstreams || []).map(function(name) { return [name, name]; })));
            var quic = dropdown([['allow',_('Разрешать')],['block',_('Блокировать')]]);
            var torrent = dropdown([['allow',_('Разрешать')],['direct',_('Напрямую')],['block',_('Блокировать')]]);
            var ttlMin = numeric(_('TTL минимум, с'), data.dns.ttl_min);
            var ttlMax = numeric(_('TTL максимум, с'), data.dns.ttl_max);
            var ttlNegative = numeric(_('TTL отрицательных ответов, с'), data.dns.ttl_negative);
            function loadPolicy() {
                var out = data.outputs.find(function(item) { return item.id === dest.value; });
                var rule = data.services.find(function(item) { return item.output === dest.value; });
                fail.value = out ? out.on_fail : 'drop';
                resolve.value = rule && rule.dns ? rule.dns : data.dns.mode;
                quic.value = rule ? rule.quic : 'allow';
                torrent.value = rule ? rule.torrent : 'allow';
            }
            dest.addEventListener('change', loadPolicy);
            loadPolicy();
            panels.settings.replaceChildren(
                E('p',{},_('Режим DNS и TTL действуют на всю конфигурацию. Остальные параметры относятся к выбранному выходу.')),
                fields([field(_('Выход'),dest),field(_('При отказе выхода'),fail),field(_('Режим DNS'),dns),
                    field(_('Разрешение доменов для правил выхода'),resolve),field(_('DNS upstream для правил выхода'),upstream),
                    field(_('QUIC'),quic),field(_('Торренты'),torrent),
                    ttlMin[0],ttlMax[0],ttlNegative[0]]),
                actions([save(function() {
                    return {type:'settings', output:dest.value, on_fail:fail.value, dns:dns.value, resolve:resolve.value,
                        quic:quic.value, torrent:torrent.value, rule_dns:upstream.value, ttl_min:ttlMin[1].valueAsNumber,
                        ttl_max:ttlMax[1].valueAsNumber, ttl_negative:ttlNegative[1].valueAsNumber};
                }, !dest.options.length)])
            );
        }

        function load(force) {
            if (!sections.length) return;
            if (pending || (!force && snapshot)) return pending;
            pending = read(entry.id).then(function(result) {
                if (result.error) {
                    snapshot = null;
                    Object.values(panels).forEach(function(panel) { panel.replaceChildren(E('p',{},result.error)); });
                    return;
                }
                snapshot = result;
                if (sections.includes('connections') || sections.includes('nodes')) renderConnections(result);
                if (sections.includes('services')) renderServices(result);
                if (sections.includes('devices')) renderDevices(result);
                if (sections.includes('exclusions')) renderExclusions(result);
                if (sections.includes('settings')) renderSettings(result);
            }, function() {
                notice.textContent = _('Не удалось прочитать настройки');
            }).finally(function() { pending = null; });
            return pending;
        }

        function tab(id, label, content) {
            return {id:'vpn-' + entry.id + '-' + id, label:label, content:content,
                activate:function() { load(false); }};
        }

        return {
            configure: function(ui, actionsAvailable) {
                sections = Array.isArray(ui.editor) ? ui.editor : [];
                capabilities = actionsAvailable || {};
                writeMode = ui.write_mode === 'live' ? 'live' : 'draft';
            },
            tabs: function() {
                var tabs = [tab('connections', _('Подключения и маршрутизация'), E('div', {}, [
                    sections.includes('connections') || sections.includes('nodes') ? panels.connections : '',
                    subsection(_('Выходы · рабочее состояние'), runtime.outputs),
                    subsection(_('Маршруты · рабочие правила'), runtime.routes),
                    sections.includes('settings') ? subsection(writeMode === 'live' ? _('Настройки DNS и выхода') :
                        _('Настройки DNS и выхода · черновик'), panels.settings) : ''
                ]))];
                if (sections.includes('services')) tabs.push(tab('services', _('Сервисы'),
                    E('div', {}, [runtime.listActions, panels.services])));
                var hasDevices = sections.includes('devices'), hasExclusions = sections.includes('exclusions');
                if (hasDevices || hasExclusions) tabs.push(tab('devices',
                    hasDevices && hasExclusions ? _('Устройства и исключения') : (hasDevices ? _('Устройства') : _('Исключения')),
                    E('div', {}, [hasDevices ? panels.devices : '', hasExclusions ? panels.exclusions : ''])));
                return tabs;
            },
            feedback: E('div',{},[notice,log]),
            refresh: function() { snapshot = null; }
        };
    }
});
