#!/usr/bin/env perl
# vim: set cc=119 ts=4 sw=4 :
use FindBin;
use lib "$FindBin::RealBin/local/lib/perl5";
use Mojolicious::Lite -signatures;
use IO::Handle;
use Text::CSV_XS;

app->config(hypnotoad => {
        listen => ['http://*:7009'],
        workers => 2,
        proxy => 1,
    });

my @sensors = qw( door lux move );
my $csv = Text::CSV_XS->new({binary => 1, sep_char  => ';', eol => $/});
my $filename = "$FindBin::RealBin/data.csv";

open my $fh, ">>", $filename or die "Unable to open $filename";
$fh->autoflush(1);

post '/' => sub ($c) {
    my $p = $c->req->json();
    return $c->render(text => "", status => 403) unless 0 == grep { not exists $p->{$_} } @sensors;

    $csv->print($fh, [
            time,
            $p->{lux} // 0,
            ($p->{move} // 0) <= 0 ? "" : $p->{move},
            ($p->{door} // 0) <= 0 ? "" : $p->{door}
        ]) or return $c->render(text => "", status => 500);

    $c->render(text => "", status => 200);
};

get '/' => sub ($c) {
    $c->render(template => 'chart');
};

get '/data' => sub ($c) {
    my $n = $c->param('n') // 2880;
    $n = 2880 if $n !~ /^\d+$/ || $n > 2_000_000;

    open my $data_fh, "<", $filename or return $c->render(text => "", status => 500);
    my @lines = <$data_fh>;
    close $data_fh;

    @lines = splice(@lines, -$n) if @lines > $n;

    my $packed = '';
    for (@lines) {
        chomp;
        my ($time, $lux, $move, $door) = split /;/;

        $move ||= 0;
        $door ||= 0;

        $lux = $lux > 4095 ? 4095 : $lux < 0 ? 0 : $lux;
        $move = $move >= 3 ? 3 : $move;
        $door = $door >= 3 ? 3 : $door;

        $packed .= pack('LS', $time, $lux | $move << 12 | $door << 14);
    }

    $c->render(format => 'bin', data => $packed);
};

get '/data.csv' => sub ($c) {
    $c->res->headers->content_type('text/plain');
    $c->reply->file($filename);
};

app->start;
__DATA__

@@ chart.html.ep
<!DOCTYPE html>
<html>
<head>
    <title>Телеметрия</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@2.0.0"></script>
    <style>
        body {
            font-size: 16px;
            margin: 0;
            padding: 0;
            overflow-x: hidden;
            font-family: Arial, sans-serif;
        }
        .chart-container {
            position: relative;
            height: 70vh; /* Уменьшена высота графика */
            width: 95vw;
            margin: 0 auto;
            touch-action: none;
        }
        .centering {
            margin: 10px auto;
            width: 95vw;
            text-align: center;
            width: fit-content;
        }
        .info-block {
            white-space: pre;
            font-size: 14px;
            padding: 5px;
            text-align: right;
            margin: 5px 0;
        }
        #hoverInfo {
            color: #666;
            font-style: italic;
        }
        input, button {
            font-size: 16px;
            padding: 8px;
        }
    </style>
</head>
<body>
    <div class="centering">
        <label for="n">Число точек:</label>
        <input type="number" id="n" name="n" min="1" max="2000000" value="2880">
        <button onclick="updateChart()">Перестроить</button>
    </div>
    <div class="centering">
        <div id="latestInfo" class="info-block"></div>
    </div>
    <div class="chart-container">
        <canvas id="myChart"></canvas>
    </div>
    <div class="centering">
        <div id="hoverInfo" class="info-block">Наведите курсор на точку для просмотра данных</div>
    </div>

    <script>
        window.addEventListener('popstate', function(event) { location.reload(); });
        let myChart = null;
        let initial_n = new URLSearchParams(window.location.search).get("n");
        if (initial_n) document.getElementById('n').value = initial_n;
        document.getElementById('n').addEventListener('keypress', function (e) {
            if (e.key === 'Enter') {
                updateChart();
            }
        });

        // Данные для скроллинга
        let isDragging = false;
        let lastX = 0;
        let velocity = 0;
        let animationFrameId = null;
        let lastTimestamp = 0;

        // Данные устройства
        let latestTimestamp = null;
        let latestDoor = null;
        let latestMove = null;
        let latestLux = null;

        function updateChart() {
            const n = document.getElementById('n').value;
            fetch(`/data?n=${n}`)
                .then(response => response.arrayBuffer())
                .then(data => {
                    const view = new DataView(data);
                    const times = [];
                    const luxValues = [];
                    const moveValues = [];
                    const doorValues = [];
                    let prevTime = null;

                    // Сбросим предыдущие данные
                    latestTimestamp = null;
                    latestDoor = null;
                    latestMove = null;
                    latestLux = null;

                    for (let i = 0; i < view.byteLength; i += 6) {
                        const time = view.getUint32(i, true);
                        const packed = view.getUint16(i + 4, true);
                        const lux = packed & 0xFFF;
                        const move = (packed >> 12) & 0x3;
                        const door = (packed >> 14) & 0x3;
                        const timestamp = new Date(time * 1000);

                        if (prevTime) {
                            for (let j = Math.floor(prevTime / 60000) + 1; j < Math.floor(timestamp / 60000); j++) {
                                times.push(new Date(j * 60000).toLocaleString('ru-RU'));
                                luxValues.push(null);
                                moveValues.push(null);
                                doorValues.push(null);
                            }
                        }
                        prevTime = timestamp;
                        latestTimestamp = timestamp.toLocaleString('ru-RU');
                        times.push(latestTimestamp);
                        luxValues.push(lux);
                        moveValues.push(move);
                        doorValues.push(door);

                        if (door > 0) latestDoor = latestTimestamp;
                        if (move > 0) latestMove = latestTimestamp;
                        if (lux !== null) latestLux = lux;
                    }

                    if (prevTime) {
                        for (let j = Math.floor(prevTime / 60000) + 1; j <= Math.floor(new Date() / 60000); j++) {
                            times.push(new Date(j * 60000).toLocaleString('ru-RU'));
                            luxValues.push(null);
                            moveValues.push(null);
                            doorValues.push(null);
                        }
                    }

                    const maxLux = Math.max(...luxValues.filter(v => v !== null));
                    const maxYValue = Math.min(Math.ceil(maxLux * 1.1), 4095);

                    const backgroundColors = determineBackgroundColors(times, doorValues, moveValues);

                    const ctx = document.getElementById('myChart').getContext('2d');
                    if (myChart) {
                        myChart.destroy();
                    }

                    // Плагин для линий при наведении
                    const cursorPlugin = {
                        id: 'cursorLines',
                        afterDraw: function(chart) {
                            if (chart.tooltip?._active?.length) {
                                const ctx = chart.ctx;
                                const activePoint = chart.tooltip._active[0];
                                const x = activePoint.element.x;
                                const y = activePoint.element.y;
                                const chartArea = chart.chartArea;

                                ctx.save();
                                // Вертикальная линия
                                ctx.beginPath();
                                ctx.moveTo(x, chartArea.top);
                                ctx.lineTo(x, chartArea.bottom);
                                ctx.lineWidth = 1;
                                ctx.strokeStyle = 'rgba(150, 150, 150, 0.5)';
                                ctx.stroke();

                                // Горизонтальная линия
                                ctx.beginPath();
                                ctx.moveTo(chartArea.left, y);
                                ctx.lineTo(chartArea.right, y);
                                ctx.strokeStyle = 'rgba(150, 150, 150, 0.3)';
                                ctx.stroke();

                                ctx.restore();
                            }
                        }
                    };

                    myChart = new Chart(ctx, {
                        type: 'line',
                        data: {
                            labels: times,
                            datasets: [
                                {
                                    label: 'Освещённость',
                                    data: luxValues,
                                    borderColor: 'rgba(136, 191, 247, 1)',
                                    backgroundColor: 'rgba(136, 191, 247, 1)',
                                    borderWidth: 1,
                                    yAxisID: 'y'
                                },
                                {
                                    label: 'Движение',
                                    data: moveValues,
                                    borderColor: 'rgba(0, 155, 100, 1)',
                                    backgroundColor: 'rgba(0, 155, 100, 1)',
                                    borderWidth: 0,
                                    pointRadius: 3,
                                    pointBackgroundColor: 'rgba(0, 155, 100, 1)',
                                    showLine: false,
                                    yAxisID: 'y1'
                                },
                                {
                                    label: 'Дверь',
                                    data: doorValues,
                                    borderColor: 'rgba(255, 0, 0, 1)',
                                    backgroundColor: 'rgba(255, 0, 0, 1)',
                                    borderWidth: 0,
                                    pointRadius: 4,
                                    pointBackgroundColor: 'rgba(255, 0, 0, 1)',
                                    showLine: false,
                                    yAxisID: 'y1'
                                }
                            ]
                        },
                        options: {
                            responsive: true,
                            maintainAspectRatio: false,
                            scales: {
                                x: {
                                    ticks: {
                                        maxRotation: 90,
                                        minRotation: 90
                                    }
                                },
                                y: {
                                    type: 'linear',
                                    display: true,
                                    position: 'left',
                                    min: 0,
                                    max: maxYValue
                                },
                                y1: {
                                    type: 'linear',
                                    display: false,
                                    position: 'right',
                                    min: 0,
                                    max: 4,
                                    grid: {
                                        drawOnChartArea: false,
                                    },
                                }
                            },
                            plugins: {
                                zoom: {
                                    zoom: {
                                        wheel: {
                                            enabled: true,
                                        },
                                        pinch: {
                                            enabled: true
                                        },
                                        mode: 'x',
                                    },
                                    pan: {
                                        enabled: false,
                                    }
                                },
                                tooltip: {
                                    enabled: false
                                },
                                legend: {
                                    display: false
                                }
                            },
                            interaction: {
                                mode: 'index',
                                intersect: false
                            }
                        },
                        plugins: [
                            cursorPlugin,
                            {
                                beforeDraw: function(chart) {
                                    const ctx = chart.ctx;
                                    const chartArea = chart.chartArea;
                                    const scales = chart.scales;
                                    backgroundColors.forEach(segment => {
                                        ctx.fillStyle = segment.color;
                                        ctx.fillRect(
                                            scales.x.getPixelForValue(segment.start),
                                            chartArea.top,
                                            scales.x.getPixelForValue(segment.end) - scales.x.getPixelForValue(segment.start),
                                            chartArea.bottom - chartArea.top
                                        );
                                    });
                                }
                            }
                        ]
                    });

                    // Скрываем нулевые точки
                    myChart.data.datasets[1].data.forEach((point, index) => {
                        if (point === 0) {
                            myChart.getDatasetMeta(1).data[index].hidden = true;
                        }
                    });
                    myChart.data.datasets[2].data.forEach((point, index) => {
                        if (point === 0) {
                            myChart.getDatasetMeta(2).data[index].hidden = true;
                        }
                    });

                    // Обновляем информацию
                    updateLatestInfo();

                    // Инициализация скроллинга
                    initChartScrolling(myChart);
                    initHoverInfo(myChart);

                    if (n != initial_n) {
                        history.pushState(n, "", "/?n=" + n);
                        initial_n = n;
                    }
                });
        }

        function updateLatestInfo() {
            document.getElementById('latestInfo').textContent =
                `Последние данные от устройства: ${latestTimestamp}\n` +
                `Дверь: ${latestDoor || 'нет данных'}\n` +
                `Движение: ${latestMove || 'нет данных'}`;
        }

        function determineBackgroundColors(times, doorValues, moveValues) {
            const segments = [];
            let segmentStart = null;
            let someoneHome = false;

            for (let i = 0; i < doorValues.length; i++) {
                if (doorValues[i] > 0) {
                    if (!someoneHome) {
                        segmentStart = times[i];
                        someoneHome = true;
                    }
                }

                if (someoneHome && doorValues[i] === 0) {
                    let hasMovement = false;
                    for (let j = i; j < moveValues.length; j++) {
                        if (moveValues[j] > 0) {
                            hasMovement = true;
                            break;
                        }
                        if (doorValues[j] > 0) {
                            break;
                        }
                    }
                    if (!hasMovement) {
                        segments.push({ start: segmentStart, end: times[i], color: 'rgba(144, 238, 144, 0.3)' });
                        someoneHome = false;
                    }
                }
            }

            if (someoneHome) {
                segments.push({ start: segmentStart, end: times[times.length - 1], color: 'rgba(144, 238, 144, 0.3)' });
            }

            return segments;
        }

        function initHoverInfo(chart) {
            const canvas = chart.canvas;
            const hoverInfo = document.getElementById('hoverInfo');

            canvas.addEventListener('mousemove', (e) => {
                const points = chart.getElementsAtEventForMode(e, 'index', { intersect: false }, true);
                if (points.length > 0) {
                    const point = points[0];
                    const index = point.index;
                    const lux = chart.data.datasets[0].data[index];
                    const move = chart.data.datasets[1].data[index];
                    const door = chart.data.datasets[2].data[index];

                    hoverInfo.textContent =
                        `Точка: ${chart.data.labels[index]}\n` +
                        `Освещённость: ${lux !== null ? lux : 'N/A'}\n` +
                        `Движение: ${move}\n` +
                        `Дверь: ${door}`;
                }
            });

            canvas.addEventListener('mouseout', () => {
                hoverInfo.textContent = 'Наведите курсор на точку для просмотра данных';
            });
        }

        function initChartScrolling(chart) {
            const canvas = chart.canvas;

            // Обработчики мыши
            canvas.addEventListener('mousedown', (e) => {
                isDragging = true;
                lastX = e.clientX;
                velocity = 0;
                lastTimestamp = performance.now();
                cancelAnimationFrame(animationFrameId);
                canvas.style.cursor = 'grabbing';
            });

            canvas.addEventListener('mousemove', (e) => {
                if (!isDragging) return;

                const now = performance.now();
                const deltaTime = now - lastTimestamp;
                lastTimestamp = now;

                const deltaX = e.clientX - lastX;
                lastX = e.clientX;

                if (deltaTime > 0) {
                    velocity = deltaX / deltaTime;
                }

                // Плавное перемещение графика
                const xScale = chart.scales.x;
                const delta = deltaX * (xScale.max - xScale.min) / xScale.width;

                chart.options.scales.x.min -= delta;
                chart.options.scales.x.max -= delta;
                chart.update('none');
            });

            canvas.addEventListener('mouseup', () => {
                isDragging = false;
                canvas.style.cursor = 'default';
                applyInertia(chart);
            });

            canvas.addEventListener('mouseleave', () => {
                if (isDragging) {
                    isDragging = false;
                    canvas.style.cursor = 'default';
                    applyInertia(chart);
                }
            });

            // Обработчики для сенсорных устройств
            const hammer = new Hammer(canvas);
            hammer.get('pan').set({ direction: Hammer.DIRECTION_HORIZONTAL });

            let lastPanX = 0;
            hammer.on('panstart', (e) => {
                isDragging = true;
                lastPanX = e.deltaX;
                velocity = 0;
                lastTimestamp = performance.now();
                cancelAnimationFrame(animationFrameId);
            });

            hammer.on('panmove', (e) => {
                if (!isDragging) return;

                const now = performance.now();
                const deltaTime = now - lastTimestamp;
                lastTimestamp = now;

                const deltaX = e.deltaX - lastPanX;
                lastPanX = e.deltaX;

                if (deltaTime > 0) {
                    velocity = deltaX / deltaTime;
                }

                const xScale = chart.scales.x;
                const delta = deltaX * (xScale.max - xScale.min) / xScale.width;

                chart.options.scales.x.min -= delta;
                chart.options.scales.x.max -= delta;
                chart.update('none');
            });

            hammer.on('panend', () => {
                isDragging = false;
                applyInertia(chart);
            });
        }

        function applyInertia(chart) {
            if (Math.abs(velocity) > 0.1) {
                const friction = 0.95;
                const animate = () => {
                    if (Math.abs(velocity) < 0.01 || isDragging) {
                        cancelAnimationFrame(animationFrameId);
                        return;
                    }

                    const xScale = chart.scales.x;
                    const delta = velocity * 15 * (xScale.max - xScale.min) / xScale.width;

                    chart.options.scales.x.min -= delta;
                    chart.options.scales.x.max -= delta;
                    chart.update('none');

                    velocity *= friction;
                    animationFrameId = requestAnimationFrame(animate);
                };
                animate();
            }
        }

        // Initial chart load
        updateChart();
    </script>
</body>
</html>
