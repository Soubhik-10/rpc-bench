param(
    [string]$Config = "bench/rpc-mainnet-like.json",
    [string]$RpcUrl,
    [int]$DurationSeconds = 0,
    [int]$Concurrency = 0,
    [int]$DiscoveryBlocks = 0
)

$ErrorActionPreference = "Stop"

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return 0
    }

    $sorted = $Values | Sort-Object
    $index = [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))
    return [Math]::Round($sorted[$index], 2)
}

function New-WeightedRequestPicker {
    param([object[]]$Requests)

    $expanded = New-Object System.Collections.Generic.List[object]
    foreach ($request in $Requests) {
        $weight = [int]$request.weight
        for ($i = 0; $i -lt $weight; $i++) {
            $expanded.Add($request)
        }
    }

    return $expanded.ToArray()
}

function ConvertFrom-HexQuantity {
    param([string]$Value)

    if (-not $Value) {
        return 0L
    }

    return [Convert]::ToInt64($Value.Substring(2), 16)
}

function ConvertTo-HexQuantity {
    param([long]$Value)

    return "0x{0:x}" -f $Value
}

function Invoke-RpcRequest {
    param(
        [string]$RpcUrl,
        [string]$Method,
        [object[]]$Params,
        [int]$TimeoutMs
    )

    $body = @{
        jsonrpc = "2.0"
        id = 1
        method = $Method
        params = $Params
    } | ConvertTo-Json -Depth 16 -Compress

    $response = Invoke-RestMethod `
        -Uri $RpcUrl `
        -Method Post `
        -ContentType "application/json" `
        -Body $body `
        -TimeoutSec ([Math]::Ceiling($TimeoutMs / 1000.0))

    if ($null -ne $response.error) {
        throw "RPC $Method failed: $($response.error.message)"
    }

    return $response.result
}

function New-DynamicContext {
    param(
        [string]$RpcUrl,
        [int]$TimeoutMs,
        [int]$BlockSampleSize
    )

    $latestHex = Invoke-RpcRequest -RpcUrl $RpcUrl -Method "eth_blockNumber" -Params @() -TimeoutMs $TimeoutMs
    $latest = ConvertFrom-HexQuantity $latestHex
    $safeLatest = [Math]::Max(0, $latest - 2)
    $sampleCount = [Math]::Max(1, $BlockSampleSize)
    $from = [Math]::Max(0, $safeLatest - $sampleCount + 1)

    $blocks = New-Object System.Collections.Generic.List[object]
    $txHashes = New-Object System.Collections.Generic.List[string]

    for ($blockNumber = $from; $blockNumber -le $safeLatest; $blockNumber++) {
        try {
            $block = Invoke-RpcRequest `
                -RpcUrl $RpcUrl `
                -Method "eth_getBlockByNumber" `
                -Params @((ConvertTo-HexQuantity $blockNumber), $true) `
                -TimeoutMs $TimeoutMs

            if ($null -ne $block) {
                $blocks.Add($block)
                foreach ($tx in @($block.transactions)) {
                    if ($tx.hash) {
                        $txHashes.Add([string]$tx.hash)
                    }
                    elseif ($tx -is [string]) {
                        $txHashes.Add($tx)
                    }
                }
            }
        }
        catch {
            Write-Warning "Skipping dynamic sample block $blockNumber`: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        enabled = $true
        latestBlock = $latest
        latestBlockHex = ConvertTo-HexQuantity $latest
        safeLatestBlock = $safeLatest
        safeLatestBlockHex = ConvertTo-HexQuantity $safeLatest
        fromBlock = $from
        fromBlockHex = ConvertTo-HexQuantity $from
        sampledBlocks = $blocks.ToArray()
        txHashes = $txHashes.ToArray()
    }
}

$configPath = Resolve-Path $Config
$bench = Get-Content -Raw -Path $configPath | ConvertFrom-Json

if ($RpcUrl) {
    $bench.rpcUrl = $RpcUrl
}
if ($DurationSeconds -gt 0) {
    $bench.durationSeconds = $DurationSeconds
}
if ($Concurrency -gt 0) {
    $bench.concurrency = $Concurrency
}
if ($DiscoveryBlocks -gt 0) {
    if ($null -eq $bench.dynamic) {
        $bench | Add-Member -MemberType NoteProperty -Name dynamic -Value ([pscustomobject]@{})
    }
    $bench.dynamic | Add-Member -Force -MemberType NoteProperty -Name blockSampleSize -Value $DiscoveryBlocks
}

$dynamicContext = [pscustomobject]@{ enabled = $false }
if ($bench.dynamic.enabled) {
    $sampleSize = 32
    if ($bench.dynamic.blockSampleSize) {
        $sampleSize = [int]$bench.dynamic.blockSampleSize
    }

    Write-Host "Discovering dynamic RPC sample from $sampleSize recent blocks..."
    $dynamicContext = New-DynamicContext -RpcUrl $bench.rpcUrl -TimeoutMs ([int]$bench.timeoutMs) -BlockSampleSize $sampleSize
    Write-Host "Latest block: $($dynamicContext.latestBlockHex)"
    Write-Host "Sample range: $($dynamicContext.fromBlockHex)..$($dynamicContext.safeLatestBlockHex)"
    Write-Host "Sampled txs:  $($dynamicContext.txHashes.Count)"
    Write-Host ""
}

$weightedRequests = New-WeightedRequestPicker -Requests $bench.requests
$deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$bench.durationSeconds)
$jobs = New-Object System.Collections.Generic.List[object]
$runspaces = [runspacefactory]::CreateRunspacePool(1, [int]$bench.concurrency)
$runspaces.Open()
$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

Write-Host "Benchmark: $($bench.name)"
Write-Host "RPC URL:   $($bench.rpcUrl)"
Write-Host "Duration:  $($bench.durationSeconds)s"
Write-Host "Workers:   $($bench.concurrency)"
Write-Host "Dynamic:   $($dynamicContext.enabled)"
Write-Host ""

for ($worker = 0; $worker -lt [int]$bench.concurrency; $worker++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $runspaces
    [void]$ps.AddScript({
        param($RpcUrl, $Deadline, $TimeoutMs, $WeightedRequests, $Results, $WorkerId, $DynamicContext)

        $random = [Random]::new($WorkerId + [Environment]::TickCount)
        $id = $WorkerId * 1000000

        function ConvertTo-HexQuantityInner {
            param([long]$Value)

            return "0x{0:x}" -f $Value
        }

        function Resolve-DynamicValue {
            param(
                [object]$Value,
                [object]$Context,
                [Random]$Random
            )

            if ($null -eq $Value) {
                return $null
            }

            if ($Value -is [string]) {
                switch ($Value) {
                    "{{latestBlock}}" { return $Context.latestBlockHex }
                    "{{safeLatestBlock}}" { return $Context.safeLatestBlockHex }
                    "{{sampleFromBlock}}" { return $Context.fromBlockHex }
                    "{{randomRecentBlock}}" {
                        $block = $Random.Next([int]$Context.fromBlock, [int]$Context.safeLatestBlock + 1)
                        return ConvertTo-HexQuantityInner $block
                    }
                    "{{randomTxHash}}" {
                        if ($Context.txHashes.Count -eq 0) {
                            return "0x0000000000000000000000000000000000000000000000000000000000000000"
                        }
                        return $Context.txHashes[$Random.Next(0, $Context.txHashes.Count)]
                    }
                    default { return $Value }
                }
            }

            if ($Value -is [System.Array]) {
                $items = New-Object System.Collections.Generic.List[object]
                foreach ($item in $Value) {
                    $items.Add((Resolve-DynamicValue -Value $item -Context $Context -Random $Random))
                }
                return $items.ToArray()
            }

            if ($Value -is [pscustomobject]) {
                $object = [ordered]@{}
                foreach ($property in $Value.PSObject.Properties) {
                    $object[$property.Name] = Resolve-DynamicValue -Value $property.Value -Context $Context -Random $Random
                }
                return [pscustomobject]$object
            }

            return $Value
        }

        while ([DateTimeOffset]::UtcNow -lt $Deadline) {
            $request = $WeightedRequests[$random.Next(0, $WeightedRequests.Count)]
            $id++
            $params = $request.params
            if ($DynamicContext.enabled) {
                $params = Resolve-DynamicValue -Value $request.params -Context $DynamicContext -Random $random
            }

            $body = @{
                jsonrpc = "2.0"
                id = $id
                method = $request.method
                params = $params
            } | ConvertTo-Json -Depth 16 -Compress

            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $ok = $false
            $errorText = $null

            try {
                $response = Invoke-RestMethod `
                    -Uri $RpcUrl `
                    -Method Post `
                    -ContentType "application/json" `
                    -Body $body `
                    -TimeoutSec ([Math]::Ceiling($TimeoutMs / 1000.0))

                $ok = $null -eq $response.error
                if (-not $ok) {
                    $errorText = $response.error.message
                }
            }
            catch {
                $errorText = $_.Exception.Message
            }
            finally {
                $timer.Stop()
            }

            $Results.Add([pscustomobject]@{
                name = $request.name
                ok = $ok
                latencyMs = $timer.Elapsed.TotalMilliseconds
                error = $errorText
            })
        }
    })
    [void]$ps.AddArgument($bench.rpcUrl)
    [void]$ps.AddArgument($deadline)
    [void]$ps.AddArgument([int]$bench.timeoutMs)
    [void]$ps.AddArgument($weightedRequests)
    [void]$ps.AddArgument($results)
    [void]$ps.AddArgument($worker)
    [void]$ps.AddArgument($dynamicContext)
    $handle = $ps.BeginInvoke()
    $jobs.Add([pscustomobject]@{
        PowerShell = $ps
        Handle = $handle
    })
}

foreach ($job in $jobs) {
    $job.PowerShell.EndInvoke($job.Handle)
    $job.PowerShell.Dispose()
}

$runspaces.Close()
$runspaces.Dispose()

$all = @($results.ToArray())
$total = $all.Count
$failures = @($all | Where-Object { -not $_.ok })
$successes = @($all | Where-Object { $_.ok })
$elapsed = [int]$bench.durationSeconds

Write-Host "Total requests: $total"
Write-Host ("Throughput:     {0:n2} req/s" -f ($total / [Math]::Max(1, $elapsed)))
Write-Host ("Success rate:   {0:p2}" -f ($successes.Count / [Math]::Max(1, $total)))
Write-Host ""

$allLatencies = [double[]]@($successes | ForEach-Object { $_.latencyMs })
Write-Host "Overall latency, successful requests only"
Write-Host ("p50={0}ms p90={1}ms p95={2}ms p99={3}ms" -f `
    (Get-Percentile $allLatencies 50), `
    (Get-Percentile $allLatencies 90), `
    (Get-Percentile $allLatencies 95), `
    (Get-Percentile $allLatencies 99))
Write-Host ""

Write-Host "Per-method summary"
$all |
    Group-Object name |
    Sort-Object Name |
    ForEach-Object {
        $group = @($_.Group)
        $okGroup = @($group | Where-Object { $_.ok })
        $latencies = [double[]]@($okGroup | ForEach-Object { $_.latencyMs })
        [pscustomobject]@{
            method = $_.Name
            count = $group.Count
            ok = $okGroup.Count
            fail = ($group.Count - $okGroup.Count)
            p50_ms = Get-Percentile $latencies 50
            p95_ms = Get-Percentile $latencies 95
            p99_ms = Get-Percentile $latencies 99
        }
    } |
    Format-Table -AutoSize

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Top errors"
    $failures |
        Group-Object error |
        Sort-Object Count -Descending |
        Select-Object -First 10 Count, Name |
        Format-Table -AutoSize
}
