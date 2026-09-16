<?php

/**
 * AWS credential diagnostics — Laravel template.
 *
 * Answers two questions: *who am I calling AWS as* and *does each call work*.
 * Credentials are never specified here — showing what the SDK default chain resolves is the test.
 *
 * HOW TO ADAPT: $checks below is a menu. Keep 'identity' — that is the whole point — and keep only
 * the services this app actually uses. Delete the rest; checking a service you do not use is noise,
 * and it tempts you into granting permissions the workload never needed.
 *
 * Two entry points share one class:
 *   - php artisan aws:check   (local; no web server or DB needed — fastest way to check a profile)
 *   - GET /test/aws           (non-production, token required; production 404s)
 *
 * Install:
 *   1) copy this class to app/Services/AwsDiagnostics.php
 *   2) routes/web.php:      Route::get('/test/aws', [TestController::class, 'aws']);
 *   3) config/services.php: 'diag' => ['token' => env('APP_DIAG_TOKEN')],
 *   4) copy the Command at the bottom to app/Console/Commands/AwsCheckCommand.php
 *
 * SES is deliberately not exercised — sending a real email is not a diagnostic.
 */

namespace App\Services;

use Aws\BedrockRuntime\BedrockRuntimeClient;
use Aws\Exception\AwsException;
use Aws\Sqs\SqsClient;
use Aws\Sts\StsClient;
use Carbon\Carbon;
use Illuminate\Support\Facades\Storage;

class AwsDiagnostics
{
    public function run(): array
    {
        $checks = [];

        // Always keep: names the principal the SDK resolved.
        $this->check($checks, 'identity', function () {
            return (new StsClient(['version' => 'latest', 'region' => config('services.ses.region', 'us-east-1')]))
                ->getCallerIdentity()['Arn'];
        });

        // ── keep only what this app uses ────────────────────────────────────
        $this->check($checks, 's3', function () {
            $body = Carbon::now()->toIso8601String();
            Storage::disk('s3')->put('diag/aws-check.txt', $body);   // fixed key, never accumulates

            return [
                'bucket' => config('filesystems.disks.s3.bucket'),
                'roundtrip' => Storage::disk('s3')->get('diag/aws-check.txt') === $body,
            ];
        });

        // $this->check($checks, 'sqs', function () {
        //     $sqs = config('queue.connections.sqs');
        //     $result = (new SqsClient(['version' => 'latest', 'region' => $sqs['region']]))->getQueueAttributes([
        //         'QueueUrl' => rtrim($sqs['prefix'], '/').'/'.$sqs['queue'],
        //         'AttributeNames' => ['ApproximateNumberOfMessages'],
        //     ]);
        //     return ['queue' => $sqs['queue'], 'messages' => $result['Attributes']['ApproximateNumberOfMessages'] ?? null];
        // });

        // $this->check($checks, 'bedrock', function () {
        //     $result = (new BedrockRuntimeClient(['version' => 'latest', 'region' => config('services.bedrock.region')]))
        //         ->invokeModel([...]);   // keep it to a 1-token reply
        //     return ['status' => $result['@metadata']['statusCode']];
        // });

        // Not included on purpose: anything with side effects a reader would not expect —
        // sending email, publishing to a topic, starting a job. Verify those via the feature itself.

        return [
            'environment' => config('app.env'),
            'aws_profile' => env('AWS_PROFILE') ?: '(unset -> default profile or role)',
            'all_ok' => collect($checks)->every(fn ($c) => $c['ok']),
            'checks' => $checks,
        ];
    }

    private function check(array &$checks, string $name, callable $fn): void
    {
        $started = microtime(true);

        try {
            // Array literals evaluate top-down, so run $fn() first or every timing reads 0 ms.
            $detail = $fn();
            $checks[$name] = ['ok' => true, 'ms' => (int) ((microtime(true) - $started) * 1000), 'detail' => $detail];
        } catch (\Throwable $e) {
            $checks[$name] = [
                'ok' => false,
                'ms' => (int) ((microtime(true) - $started) * 1000),
                'error' => $e instanceof AwsException ? (string) $e->getAwsErrorCode() : class_basename($e),
                'message' => mb_substr($e->getMessage(), 0, 300),
            ];
        }
    }
}

/* ---------------------------------------------------------------------------
 * app/Console/Commands/AwsCheckCommand.php
 *
 * class AwsCheckCommand extends Command
 * {
 *     protected $signature = 'aws:check';
 *     protected $description = 'Show which AWS identity this app authenticates as, and whether each service call works';
 *
 *     public function handle(AwsDiagnostics $diagnostics): int
 *     {
 *         $data = $diagnostics->run();
 *         $this->line('  AWS_PROFILE : '.$data['aws_profile']);
 *         $this->line('  calling as  : '.($data['checks']['identity']['detail'] ?? '(failed)'));
 *         $this->table(['', 'check', 'ms', 'result'], collect($data['checks'])->map(fn ($c, $n) => [
 *             $c['ok'] ? '✅' : '❌', $n, $c['ms'].' ms',
 *             $c['ok'] ? json_encode($c['detail'], JSON_UNESCAPED_UNICODE) : $c['error'].': '.$c['message'],
 *         ])->values()->all());
 *
 *         return $data['all_ok'] ? self::SUCCESS : self::FAILURE;
 *     }
 * }
 *
 * ---------------------------------------------------------------------------
 * TestController::aws() — guard excerpt
 *
 *   $env = config('app.env');
 *   if ($env !== 'local') {
 *       $expected = (string) config('services.diag.token');
 *       $token = $request->header('X-Diag-Token') ?: (string) $request->query('token', '');
 *       if ($env !== 'stage' || $expected === '' || !hash_equals($expected, $token)) {
 *           abort(404);
 *       }
 *   }
 *   $data = $diagnostics->run();   // then render an HTML table or return JSON
 * ------------------------------------------------------------------------- */
