#!/usr/bin/env perl
# vim: cc=119 :
use FindBin;
use lib "$FindBin::RealBin/local/lib/perl5";
use Mojolicious::Lite -signatures;
use IO::Handle;
use Text::CSV_XS;

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

app->start;
__DATA__

@@ chart.html.ep
<!DOCTYPE html>
<html>
<head>
    <title>Телеметрия</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        .chart-container {
            position: relative;
            height: 85vh;
            width: 90vw;
            margin: 0 auto;
        }
        .centering {
            margin: 10px auto;
            display: block;
            width: fit-content;
        }
    </style>
</head>
<body>
    <div class="centering">
        <label for="n">Число точек:</label>
        <input type="number" id="n" name="n" min="1" max="2000000" value="2880">
        <button onclick="updateChart()">Перестроить</button>
    </div>
    <div class="chart-container">
        <canvas id="myChart"></canvas>
    </div>
    <script>
        let myChart = null; // Declare myChart in a higher scope

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

                    for (let i = 0; i < view.byteLength; i += 6) {
                        const time = view.getUint32(i, true);
                        const packed = view.getUint16(i + 4, true);
                        const lux = packed & 0xFFF;
                        const move = (packed >> 12) & 0x3;
                        const door = (packed >> 14) & 0x3;

                        times.push(new Date(time * 1000).toLocaleString());
                        luxValues.push(lux);
                        moveValues.push(move);
                        doorValues.push(door);
                    }

                    const maxLux = Math.max(...luxValues);
                    const maxYValue = Math.min(Math.floor(maxLux * 1.1), 4095);

                    const ctx = document.getElementById('myChart').getContext('2d');
                    if (myChart) {
                        myChart.destroy();
                    }
                    myChart = new Chart(ctx, {
                        type: 'line',
                        data: {
                            labels: times,
                            datasets: [
                                {
                                    label: 'Освещённость',
                                    data: luxValues,
                                    borderColor: 'rgba(136, 191, 247, 1)',
                                    borderWidth: 0,
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
                                    display: false, // Hide the y1 axis
                                    position: 'right',
                                    min: 0,
                                    max: 4,
                                    grid: {
                                        drawOnChartArea: false,
                                    },
                                }
                            },
                            plugins: {
                                tooltip: {
                                    mode: 'index',
                                    intersect: false
                                }
                            }
                        }
                    });

                    // Hide points with zero values
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

                    myChart.update();
                });
        }

        // Initial chart load
        updateChart();
    </script>
</body>
</html>
