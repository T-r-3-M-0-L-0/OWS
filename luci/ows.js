'use strict';
'require view';
'require rpc';
'require poll';
'require request';
'require session';
'require ui';
'require view.ows-templates as templates';
'require view.ows-zapret as zapret';
'require view.ows-zapret-tools as zapretTools';
'require view.ows-dns as dns';

var status = rpc.declare({ object: 'ows', method: 'status' });
var jobStatus = rpc.declare({ object: 'ows', method: 'job_status', params: ['job'] });
var jobOutput = rpc.declare({ object: 'ows', method: 'job_output', params: ['job'] });
var catalog = rpc.declare({ object: 'ows', method: 'catalog' });
var parameters = ['profile', 'line', 'action', 'blob', 'expected'];
var preview = rpc.declare({ object: 'ows', method: 'preview', params: parameters });
var applyAction = rpc.declare({ object: 'ows', method: 'apply_action', params: parameters });
var moduleList = rpc.declare({ object: 'ows', method: 'module_list' });
var moduleStatus = rpc.declare({ object: 'ows', method: 'module_status', params: ['id'] });
var modulePreview = rpc.declare({ object: 'ows', method: 'module_preview', params: ['manifest'] });
var moduleAttach = rpc.declare({ object: 'ows', method: 'module_attach', params: ['manifest'] });
var moduleLink = rpc.declare({ object: 'ows', method: 'module_link', params: ['name', 'source'] });

var labels = {
    idle: _('Нет операций'),
    queued: _('В очереди'),
    validating: _('Проверка конфигурации'),
    applying: _('Применение'),
    applied: _('Применено'),
    invalid_config: _('Проверка конфигурации не пройдена'),
    config_changed: _('Конфигурация изменилась. Обновите редактор'),
    config_busy: _('Идёт проверка Zapret2 по расписанию'),
    snapshot_failed: _('Не удалось создать снимок'),
    rolling_back: _('Откат'),
    rolled_back: _('Предыдущая конфигурация восстановлена'),
    rollback_failed: _('Ошибка отката. Требуется вмешательство'),
    interrupted: _('Операция прервана'),
    done: _('Операция завершена'),
    operation_failed: _('Ошибка операции')
};

var stgwsActions = {
    check: _('Проверка MTProto'),
    restart: _('Перезапуск'),
    reconfigure: _('Подбор домена'),
    route_smart: _('Умная карта'),
    route_save: _('Сохранение карты'),
    route_restore: _('Восстановление карты'),
    install: _('Установка пакета'),
    update: _('Обновление пакета'),
    reinstall: _('Переустановка пакета'),
    remove: _('Удаление пакета')
};

function statusLabel(result, template) {
    var label = labels[result.phase] || _('Статус неизвестен');
    if (template && template.jobActions && Object.prototype.hasOwnProperty.call(template.jobActions, result.action)) {
        return (template.jobName || result.kind) + ' · ' + template.jobActions[result.action] + ' · ' + label;
    }
    if (result.kind === 'zapret-module') {
        var parts = (result.action || '').split(':');
        var operation = {
            download:_('Скачивание пакетов'), install:_('Установка пакетов'),
            start:_('Запуск'), stop:_('Остановка'), restart:_('Перезапуск'),
            enable:_('Включение автозапуска'), disable:_('Выключение автозапуска'),
            'compare-start':_('Сравнение стратегий'), 'compare-stop':_('Остановка сравнения'),
            'schedule-set':_('Настройка расписания')
        }[parts[1]] || _('Конструктор');
        return (parts[0] === 'zapret2' ? 'Zapret2' : 'Zapret') + ' · ' + operation + ' · ' + label;
    }
    if (result.kind === 'dns') return _('Проверка DNS') + ' · ' + label;
    if (result.kind && result.kind !== 'stgws' && result.kind !== 'zapret2') {
        var operation = result.action === 'diag' ? _('Диагностика') :
            result.action === 'prepare-migration' ? _('Подготовка переноса') :
            result.action === 'check-handover' ? _('Проверка готовности к передаче') :
            result.action === 'refresh-draft-subscription' ? _('Обновление подписки в черновике') :
            result.action === 'test-draft-lists' ? _('Проверка обновления списков') :
            result.action === 'takeover' ? _('Передача управления') :
            result.action === 'refresh-live-lists' ? _('Обновление рабочих списков') :
            result.action === 'refresh-live-subscription' ? _('Обновление рабочей подписки') :
            result.action === 'edit' ? _('Изменение конфигурации') :
            (result.action || '').indexOf('preview-draft:') === 0 ? _('Проверка черновика') :
            (result.action || '').indexOf('apply-draft:') === 0 ? _('Применение черновика') :
            (result.action || '').indexOf('probe:') === 0 ? _('Проверка узла') :
            (result.action || '').indexOf('probe-all:') === 0 ? _('Проверка всех узлов') :
            (result.action || '').indexOf('list-preview:') === 0 ? _('Просмотр состава сервиса') : _('Проверка подписки');
        return result.kind + ' · ' + operation + ' · ' + label;
    }
    if (result.kind !== 'stgws') return label;
    var action = stgwsActions[result.action] || _('Настройки');
    if (result.action === 'check' && result.phase === 'operation_failed') {
        return _('sTGWS · Проверка MTProto не пройдена');
    }
    return 'sTGWS · ' + action + ' · ' + label;
}

function createTabs(name, tabs, initial, onChange) {
    var links = [];
    var panels = [];
    var active = -1;
    var menu = E('ul', { class: 'cbi-tabmenu ows-tabmenu', role: 'tablist', 'aria-label': name });

    function select(index, focus) {
        if (index === active) {
            if (focus) links[index].focus();
            return;
        }
        active = index;
        links.forEach(function(link, i) {
            var selected = i === index;
            link.parentNode.className = selected ? 'cbi-tab' : 'cbi-tab-disabled';
            link.setAttribute('aria-selected', String(selected));
            link.tabIndex = selected ? 0 : -1;
            panels[i].hidden = !selected;
        });
        if (focus) links[index].focus();
        if (tabs[index].activate) tabs[index].activate();
        if (onChange) onChange(tabs[index].id);
    }

    tabs.forEach(function(tab, index) {
        var id = 'ows-tab-' + tab.id;
        var panel = E('section', { id: id + '-panel', role: 'tabpanel', 'aria-labelledby': id }, tab.content);
        var link = E('a', { id: id, href: '#' + panel.id, role: 'tab', 'aria-controls': panel.id }, tab.label);
        link.addEventListener('click', function(event) {
            event.preventDefault();
            select(index, false);
        });
        link.addEventListener('keydown', function(event) {
            var next;
            switch (event.key) {
            case 'ArrowRight': next = (index + 1) % tabs.length; break;
            case 'ArrowLeft': next = (index + tabs.length - 1) % tabs.length; break;
            case 'Home': next = 0; break;
            case 'End': next = tabs.length - 1; break;
            case ' ': next = index; break;
            default: return;
            }
            event.preventDefault();
            select(next, true);
        });
        links.push(link);
        panels.push(panel);
        menu.appendChild(E('li', { role: 'presentation' }, link));
    });

    var content = E('div', {}, [menu].concat(panels));
    var start = typeof initial === 'string' ? tabs.findIndex(function(tab) { return tab.id === initial; }) : initial;
    select(start > 0 ? start : 0, false);
    return {
        content: content,
        select: function(index) { select(index, true); },
        selectedId: function() { return tabs[active].id; }
    };
}

function renderResources(container, data) {
    var profiles = data.profiles || [];
    var names = data.blobs || [];
    var usage = Object.create(null);

    profiles.forEach(function(profile) {
        var used = Object.create(null);
        var matches = (profile.script || '').matchAll(/(?:^|:)\s*(?:blob|seqovl_pattern)=([A-Za-z0-9_]+)(?=[:\s]|$)/gm);
        for (var match of matches) used[match[1]] = true;
        Object.keys(used).forEach(function(name) {
            if (!usage[name]) usage[name] = [];
            usage[name].push(profile.name);
        });
    });

    var rows = names.map(function(name) {
        return E('tr', { class: 'tr' }, [
            E('td', { class: 'td' }, E('code', {}, name)),
            E('td', { class: 'td' }, (usage[name] || []).join(', ') || '—')
        ]);
    });
    container.replaceChildren(
        E('h4', {}, _('Доступные blob')),
        rows.length ? E('table', { class: 'table ows-blob-table' }, [
            E('thead', {}, E('tr', { class: 'tr table-titles' }, [
                E('th', { class: 'th', scope: 'col' }, _('Blob')),
                E('th', { class: 'th', scope: 'col' }, _('Тактики'))
            ])),
            E('tbody', {}, rows)
        ]) : E('p', {}, _('Нет доступных blob'))
    );
}

function field(id, label, input) {
    return E('div', { class: 'ows-field' }, [E('label', { for: id }, label), input]);
}

function entrySource(entry) {
    if (!/^https:\/\//.test(entry.source || '')) return null;
    return E('a', { href: entry.source, target: '_blank', rel: 'noopener noreferrer' }, _('Открыть источник'));
}

function adapterTab(entry) {
    var state = E('p', { 'aria-live': 'polite' });
    function loadStatus() {
        state.textContent = _('Читаем состояние службы');
        return moduleStatus(entry.id).then(function(result) {
            var states = { running: _('Работает'), stopped: _('Остановлена'), unknown: _('Состояние недоступно') };
            state.textContent = result.error || states[result.state] || _('Состояние недоступно');
        }, function() {
            state.textContent = _('Не удалось прочитать состояние службы');
        });
    }
    var refresh = E('button', { type: 'button', class: 'cbi-button' }, _('Обновить статус'));
    refresh.addEventListener('click', loadStatus);
    var detail = createTabs(_('Разделы модуля'), [
        { id: 'module-' + entry.id + '-status', label: _('Состояние'), content: [
            E('p', {}, [_('Служба'), ' ', E('code', {}, entry.service)]), state, refresh
        ] },
        { id: 'module-' + entry.id + '-source', label: _('Адаптер'), content: [
            E('p', {}, [_('Версия'), ' ', entry.version]), E('p', {}, entry.description || ''),
            entrySource(entry)
        ].filter(Boolean) }
    ]);
    return {
        id: 'module-' + entry.id, label: entry.name, activate: loadStatus,
        content: [E('h3', {}, entry.name), detail.content]
    };
}

function adapterCatalog(onChange) {
    var list = E('div');
    var notice = E('p', { 'aria-live': 'polite' });
    var previewPane = E('div');
    var name = E('input', { id: 'ows-link-name', class: 'cbi-input-text', type: 'text', maxlength: 64 });
    var source = E('input', { id: 'ows-link-url', class: 'cbi-input-text', type: 'url', maxlength: 512 });
    var file = E('input', { id: 'ows-manifest', type: 'file', accept: '.json,application/json' });
    var save = E('button', { class: 'cbi-button', type: 'button' }, _('Сохранить ссылку'));
    var inspect = E('button', { class: 'cbi-button', type: 'button' }, _('Проверить манифест'));
    var refresh = E('button', { class: 'cbi-button', type: 'button' }, _('Обновить каталог'));

    function load() {
        refresh.disabled = true;
        return moduleList().then(function(result) {
            if (result.error) notice.textContent = result.error;
            else onChange(result.entries || [], result.vpn_drivers || {});
        }, function() {
            notice.textContent = _('Не удалось прочитать каталог');
        }).finally(function() { refresh.disabled = false; });
    }

    function store(request, button, message) {
        button.disabled = true;
        return request.then(function(result) {
            notice.textContent = result.error || message;
            if (!result.id) return;
            previewPane.replaceChildren();
            return load();
        }, function() {
            notice.textContent = _('Не удалось сохранить. Проверьте права на запись.');
        }).finally(function() { button.disabled = false; });
    }

    refresh.addEventListener('click', load);
    save.addEventListener('click', function() {
        store(moduleLink(name.value.trim(), source.value.trim()), save, _('Ссылка сохранена'));
    });
    file.addEventListener('change', function() { previewPane.replaceChildren(); });
    inspect.addEventListener('click', function() {
        var upload = file.files[0];
        previewPane.replaceChildren();
        if (!upload || upload.size > 4096) {
            notice.textContent = _('Выберите JSON-манифест размером до 4 КиБ');
            return;
        }
        inspect.disabled = true;
        upload.text().then(function(text) {
            return modulePreview(text).then(function(result) {
                if (file.files[0] !== upload) return;
                notice.textContent = result.error || '';
                if (result.error) return;
                var attach = E('button', { class: 'cbi-button cbi-button-apply', type: 'button' }, _('Подключить адаптер'));
                attach.addEventListener('click', function() {
                    store(moduleAttach(text), attach, _('Адаптер подключён'));
                });
                previewPane.replaceChildren(
                    E('h4', {}, result.name),
                    E('p', {}, [result.version, ' · ', E('code', {}, result.service),
                        result.category === 'proxy' ? ' · ' + _('Прокси') : '']),
                    E('p', {}, result.description || ''),
                    attach
                );
            });
        }).catch(function() {
            notice.textContent = _('Не удалось проверить манифест');
        }).finally(function() { inspect.disabled = false; });
    });

    var content = E('div', {}, [
        E('div', { class: 'ows-module-heading' }, [E('h3', {}, _('Модули')), refresh]),
        list,
        E('details', { class: 'ows-overview ows-catalog-add' }, [
            E('summary', {}, _('Добавить решение')),
            E('h4', {}, _('Ссылка')),
            E('div', { class: 'ows-fields' }, [
                field('ows-link-name', _('Название'), name), field('ows-link-url', _('Источник HTTPS'), source)
            ]),
            E('div', { class: 'ows-actions' }, save),
            E('h4', {}, _('Манифест адаптера')),
            field('ows-manifest', _('Файл JSON'), file),
            E('div', { class: 'ows-actions' }, inspect),
            previewPane
        ]),
        notice
    ]);
    return { content: content, list: list, load: load };
}

return view.extend({
    load: function() {
        var localTemplates = templates.load();
        var services = session.getLocalData('menu')?.children?.admin?.children?.services?.children;
        if (!services?.zapret2?.satisfied) return localTemplates;

        return request.get(L.url('admin', 'menu'), { cache: false, timeout: 3000 }).then(function(response) {
            if (!response.ok) return;
            var current = response.json()?.children?.admin?.children?.services?.children;
            if (current?.ows?.satisfied && !current?.zapret2?.satisfied) {
                ui.menu.flushCache();
                if (!session.getLocalData('menu')) window.location.reload();
            }
        }).catch(function() {
            // The menu refresh must not prevent the OWS panel from opening.
        }).then(function() {
            return localTemplates;
        });
    },

    render: function(templateWarning) {
        var phase = E('p', { class: 'ows-phase', 'aria-live': 'polite' }, _('Загрузка статуса'));
        var job = E('code');
        var outputJob = '';
        var outputText = E('pre', { class: 'ows-job-output' });
        var details = E('details', { hidden: '' }, [E('summary', {}, _('Журнал задания')), outputText]);
        var selectedJob = '';
        var nextRefresh = 0;
        var jobObservers = Object.create(null);
        var moduleTemplates = Object.create(null);
        var editor = E('div');
        var resources = E('div');
        var catalogLoaded = false;
        var catalogRequest = null;
        var notice = E('p', { 'aria-live': 'polite' });
        var refreshButton = E('button', { 'type': 'button', 'class': 'cbi-button' }, _('Обновить тактики'));

        function loadOutput() {
            var id = outputJob;
            if (!details.open || !id) return;
            outputText.textContent = _('Читаем журнал задания');
            return jobOutput(id).then(function(result) {
                if (id === outputJob) outputText.textContent = result.output || _('Журнал пуст');
            }, function() {
                if (id === outputJob) outputText.textContent = _('Не удалось прочитать журнал');
            });
        }
        details.addEventListener('toggle', loadOutput);

        function activePhase(phase) {
            return ['queued', 'validating', 'applying', 'rolling_back'].includes(phase);
        }

        function refresh(force) {
            var now = Date.now();
            if (!force && now < nextRefresh) return;
            var id = selectedJob;
            var request = id ? jobStatus(id) : status();
            function notify(result) {
                var observer = jobObservers[result.job];
                if (!observer || activePhase(result.phase)) return;
                delete jobObservers[result.job];
                observer(result);
            }
            var other = Object.keys(jobObservers).filter(function(key) { return key !== id; });
            nextRefresh = now + (other.length || jobObservers[id] ? 3000 : 15000);
            var primary = request.then(function(result) {
                notify(result);
                if (id !== selectedJob) return;
                if (activePhase(result.phase)) nextRefresh = Date.now() + 3000;
                phase.textContent = statusLabel(result, moduleTemplates[result.kind]);
                job.textContent = result.job || '';
                var nextOutput = result.has_output && result.phase !== 'applying' ? result.job : '';
                if (nextOutput !== outputJob) {
                    outputJob = nextOutput;
                    details.open = false;
                    details.hidden = !outputJob;
                    outputText.textContent = '';
                }
            }, function() {
                if (id !== selectedJob) return;
                phase.textContent = _('Не удалось получить статус OWS');
                job.textContent = '';
                details.hidden = true;
                outputJob = '';
            });
            return Promise.all([primary].concat(other.map(function(key) {
                return jobStatus(key).then(notify, function() {});
            })));
        }

        function followJob(id, observer) {
            selectedJob = id;
            if (observer) jobObservers[id] = observer;
            refresh(true);
        }

        function option(value, title) {
            return E('option', { value: value }, title || value);
        }

        function build(data) {
            var profiles = data.profiles || [];
            if (!profiles.length) {
                editor.replaceChildren(E('p', {}, _('В конфигурации нет тактик')));
                return;
            }
            var profile = E('select', { id: 'ows-profile', class: 'cbi-input-select' },
                profiles.map(function(item) { return option(item.name); }));
            var line = E('select', { id: 'ows-line', class: 'cbi-input-select' });
            var action = E('select', { id: 'ows-action', class: 'cbi-input-select' }, ['fake', 'multisplit', 'multidisorder'].map(function(name) {
                return option(name);
            }));
            var blob = E('select', { id: 'ows-blob', class: 'cbi-input-select' }, [option('', _('Выберите blob'))].concat(
                (data.blobs || []).map(function(name) { return option(name); })));
            var reviewButton = E('button', { type: 'button', 'class': 'cbi-button' }, _('Предпросмотр'));
            var applyButton = E('button', { type: 'button', 'class': 'cbi-button cbi-button-apply', disabled: '' }, _('Поставить в очередь'));
            var review = E('div', { class: 'ows-review' });
            var approved = null;
            var change = 0;
            var busy = false;

            function invalidate() {
                change++;
                approved = null;
                applyButton.disabled = true;
                review.replaceChildren();
                blob.disabled = action.value !== 'fake';
            }

            function loadLines() {
                var script = profiles[profile.selectedIndex].script || '';
                var items = [option('0', _('Добавить действие в конец'))];
                script.split('\n').forEach(function(text, index) {
                    if (/^\s*--lua-desync=[A-Za-z0-9_]+(?::[^\s"'\\]+)?\s*$/.test(text)) {
                        items.push(option(String(index + 1), text.trim()));
                    }
                });
                line.replaceChildren.apply(line, items);
                loadAction();
            }

            function loadAction() {
                var script = profiles[profile.selectedIndex].script || '';
                var text = script.split('\n')[Number(line.value) - 1] || '';
                var name = text.trim().match(/^--lua-desync=([A-Za-z0-9_]+)/);
                var assigned = text.match(/:blob=([A-Za-z0-9_]+)(?=:|\s|$)/);
                action.value = name && ['fake', 'multisplit', 'multidisorder'].indexOf(name[1]) >= 0 ? name[1] : 'fake';
                blob.value = assigned && (data.blobs || []).indexOf(assigned[1]) >= 0 ? assigned[1] : '';
                invalidate();
            }

            profile.addEventListener('change', loadLines);
            line.addEventListener('change', loadAction);
            action.addEventListener('change', invalidate);
            blob.addEventListener('change', invalidate);
            reviewButton.addEventListener('click', function() {
                if (busy) return;
                invalidate();
                var version = change;
                var request = [profile.value, line.value, action.value, blob.disabled ? '' : blob.value, data.revision];
                notice.textContent = _('Проверяем выбранное действие');
                preview.apply(null, request).then(function(result) {
                    if (version !== change) return;
                    notice.textContent = result.error || '';
                    if (result.error) return;
                    review.replaceChildren(
                        E('div', {}, [E('h4', {}, _('До')), E('pre', {}, String(result.before || ''))]),
                        E('div', {}, [E('h4', {}, _('После')), E('pre', {}, String(result.after || ''))])
                    );
                    if (result.before !== result.after) {
                        approved = request;
                        applyButton.disabled = false;
                    } else {
                        notice.textContent = _('Изменений нет');
                    }
                }, function() {
                    if (version === change) notice.textContent = _('Не удалось получить предпросмотр');
                });
            });

            applyButton.addEventListener('click', function() {
                if (!approved || busy) return;
                busy = true;
                applyButton.disabled = true;
                applyAction.apply(null, approved).then(function(result) {
                    busy = false;
                    if (!result.job) {
                        notice.textContent = result.error || _('Не удалось поставить задание в очередь');
                        return;
                    }
                    invalidate();
                    notice.textContent = _('Задание поставлено в очередь. После завершения обновите тактики.');
                    followJob(result.job);
                }, function() {
                    busy = false;
                    notice.textContent = _('Не удалось отправить задание. Проверьте права на запись.');
                });
            });

            loadLines();
            editor.replaceChildren(
                E('div', { class: 'ows-fields' }, [
                    field('ows-profile', _('Тактика'), profile),
                    field('ows-line', _('Шаг'), line),
                    field('ows-action', _('Lua-действие'), action),
                    field('ows-blob', _('Blob для fake'), blob)
                ]),
                E('div', { class: 'ows-actions' }, [reviewButton, applyButton]), review
            );
        }

        function loadCatalog() {
            if (catalogRequest) return catalogRequest;
            refreshButton.disabled = true;
            editor.replaceChildren();
            resources.replaceChildren();
            notice.textContent = _('Читаем тактики zapret2');
            catalogRequest = catalog().then(function(data) {
                notice.textContent = data.error || '';
                if (data.error) return;
                build(data);
                renderResources(resources, data);
                catalogLoaded = true;
            }, function() {
                notice.textContent = _('Не удалось прочитать тактики');
            }).finally(function() {
                refreshButton.disabled = false;
                catalogRequest = null;
            });
            return catalogRequest;
        }

        var classicModule = zapret.init('zapret', followJob);
        var zapret2Module = zapret.init('zapret2', followJob);
        var nativeHash = '#ows-tab-zapret2-native-panel';
        var openNative = window.location.hash === nativeHash;
        var modules;

        function rememberNativeTab(active) {
            if (active && window.location.hash !== nativeHash)
                window.history.replaceState(window.history.state, '', nativeHash);
            else if (!active && window.location.hash === nativeHash)
                window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
        }

        refreshButton.addEventListener('click', function() {
            catalogLoaded = false;
            zapret2Module.refresh();
            loadCatalog();
        });
        var classicTabs = createTabs(_('Разделы Zapret'), [
            {id:'zapret-service',label:_('Служба и пакеты'),content:classicModule.status},
            classicModule.native
        ]);
        var zapret2 = createTabs(_('Разделы Zapret2'), [
            { id: 'zapret2-service', label: _('Служба и пакеты'), content: zapret2Module.status },
            { id: 'zapret2-tactics', label: _('Тактики'), content: editor, activate: function() {
                if (!catalogLoaded) loadCatalog();
            } },
            { id: 'zapret2-resources', label: _('Ресурсы'), content: resources, activate: function() {
                if (!catalogLoaded) loadCatalog();
            } },
            zapret2Module.native,
            { id: 'zapret2-constructor', label: _('Конструктор Zapret2'), content: zapret2Module.constructor,
                activate: zapret2Module.loadConstructor },
            templates.panel(zapretTools.presets(followJob)),
            templates.panel(zapretTools.comparison(followJob))
        ], openNative ? zapret2Module.native.id : null, function(id) {
            if (modules && modules.selectedId() === 'zapret2') rememberNativeTab(id === zapret2Module.native.id);
        });
        var workspace = E('div');
        var registry = adapterCatalog(renderModules);
        var selectedProxy;
        var zapret2Panel = E('div', {}, [
            E('div', { class: 'ows-module-heading' }, [E('h3', {}, _('Zapret2')), refreshButton]),
            notice, zapret2.content, zapret2Module.feedback
        ]);

        function renderModules(entries, vpnDrivers) {
            moduleTemplates = Object.create(null);
            var tabs = [
                { id: 'overview', label: _('Обзор'), content: registry.content },
                { id: 'zapret2', label: _('Zapret2'), activate: zapret2Module.refresh, content: zapret2Panel },
                { id: 'zapret', label: _('Zapret'), activate: classicModule.refresh,
                    content: E('div', {}, [E('h3', {}, _('Zapret')), classicTabs.content, classicModule.feedback]) }
            ];
            var rows = [
                {name:'Zapret2',description:_('Движок nfqws2, редактор тактик и конструктор'),tab:1},
                {name:'Zapret',description:_('Первая версия, движок nfqws'),tab:2}
            ];
            var proxyTabs = [];
            var proxyContent = E('div');
            var proxyTabIndex = tabs.length;
            var proxyModules;
            var proxyGroup = templates.proxyGroup();
            var context = { createTabs: createTabs, followJob: followJob };

            function openProxies(index) {
                if (proxyModules) {
                    if (index != null) proxyModules.select(index);
                    return;
                }
                if (!proxyTabs.length) {
                    proxyContent.replaceChildren(E('p', {}, proxyGroup.empty));
                    return;
                }
                proxyModules = createTabs(proxyGroup.sectionsLabel, proxyTabs, index == null ? selectedProxy : index,
                    function(id) { selectedProxy = id; });
                proxyContent.replaceChildren(proxyModules.content);
            }

            tabs.push({ id: 'proxies', label: proxyGroup.label, content: proxyContent, activate: openProxies });
            tabs.push(templates.panel(dns.tab(followJob)));
            entries.forEach(function(entry) {
                if (entry.id === 'zapret' || entry.id === 'zapret2') return;
                if (entry.kind !== 'adapter') {
                    rows.push(entry);
                    return;
                }
                var template = templates.resolve(entry, vpnDrivers);
                moduleTemplates[entry.id] = template;
                if (template.label) entry = Object.assign({}, entry, { name: template.label });
                var tab = (template.tab && template.tab(entry, context, template)) || adapterTab(entry);
                if (template.proxy) {
                    rows.push(Object.assign({ tab: proxyTabIndex, proxy: proxyTabs.length }, entry));
                    proxyTabs.push(tab);
                } else {
                    rows.push(Object.assign({ tab: tabs.length }, entry));
                    tabs.push(tab);
                }
            });
            registry.list.replaceChildren.apply(registry.list, rows.map(function(entry) {
                var actions = [];
                if (entry.tab != null) {
                    var open = E('button', { class: 'cbi-button', type: 'button' }, _('Открыть'));
                    open.addEventListener('click', function() {
                        if (entry.proxy != null) openProxies(entry.proxy);
                        modules.select(entry.tab);
                    });
                    actions.push(open);
                }
                var link = entrySource(entry);
                if (link) actions.push(link);
                return E('section', { class: 'ows-overview' }, [
                    E('div', {}, [
                        E('h4', {}, entry.name),
                        E('p', {}, entry.kind === 'link' ? _('Сохранённая ссылка') :
                            (entry.version ? _('Адаптер') + ' · ' + entry.version : entry.description))
                    ]),
                    E('div', { class: 'ows-actions ows-entry-actions' }, actions)
                ]);
            }));
            var active = modules ? modules.selectedId() : openNative ? 'zapret2' : 'overview';
            modules = createTabs(_('Модули OWS'), tabs, active, function(id) {
                rememberNativeTab(id === 'zapret2' && zapret2.selectedId() === zapret2Module.native.id);
            });
            workspace.replaceChildren(modules.content);
        }

        renderModules([], {});
        registry.load();
        refresh();
        poll.add(function() { return refresh(false); }, 3);
        return E('div', { class: 'ows' }, [
            E('link', { rel: 'stylesheet', href: L.resource('view/ows-services.css') }),
            E('h2', {}, _('OWS')),
            templateWarning ? E('p', { role: 'status' }, templateWarning) : '',
            E('section', { class: 'ows-status', 'aria-label': _('Очередь OWS') }, [
                E('strong', {}, _('Последняя операция')),
                phase,
                job,
                details
            ]),
            workspace
        ]);
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
