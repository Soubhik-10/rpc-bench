param(
    [string]$RpcUrl = "http://127.0.0.1:8545",
    [int]$TimeoutMs = 15000
)

$ErrorActionPreference = "Stop"

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

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod `
            -Uri $RpcUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec ([Math]::Ceiling($TimeoutMs / 1000.0))

        $timer.Stop()
        if ($null -ne $response.error) {
            return [pscustomobject]@{
                method = $Method
                ok = $false
                latencyMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
                result = $null
                error = $response.error.message
            }
        }

        return [pscustomobject]@{
            method = $Method
            ok = $true
            latencyMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            result = $response.result
            error = $null
        }
    }
    catch {
        $timer.Stop()
        return [pscustomobject]@{
            method = $Method
            ok = $false
            latencyMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            result = $null
            error = $_.Exception.Message
        }
    }
}

Write-Host "RPC probe: $RpcUrl"
Write-Host ""

$checks = @(
    @{ method = "web3_clientVersion"; params = @() },
    @{ method = "eth_chainId"; params = @() },
    @{ method = "net_version"; params = @() },
    @{ method = "net_peerCount"; params = @() },
    @{ method = "eth_syncing"; params = @() },
    @{ method = "eth_blockNumber"; params = @() },
    @{ method = "txpool_status"; params = @() }
)

$results = foreach ($check in $checks) {
    Invoke-RpcRequest -RpcUrl $RpcUrl -Method $check.method -Params $check.params -TimeoutMs $TimeoutMs
}

$results |
    Select-Object method, ok, latencyMs, @{ Name = "summary"; Expression = {
        if (-not $_.ok) {
            return $_.error
        }
        $json = $_.result | ConvertTo-Json -Depth 8 -Compress
        if ($json.Length -gt 120) {
            return $json.Substring(0, 120) + "..."
        }
        return $json
    }} |
    Format-Table -AutoSize

$blockNumber = @($results | Where-Object { $_.method -eq "eth_blockNumber" -and $_.ok })[0]
if ($blockNumber) {
    $latestBlock = Invoke-RpcRequest `
        -RpcUrl $RpcUrl `
        -Method "eth_getBlockByNumber" `
        -Params @($blockNumber.result, $false) `
        -TimeoutMs $TimeoutMs

    Write-Host ""
    Write-Host "Latest block header"
    if ($latestBlock.ok) {
        [pscustomobject]@{
            number = $latestBlock.result.number
            hash = $latestBlock.result.hash
            transactions = @($latestBlock.result.transactions).Count
            gasUsed = $latestBlock.result.gasUsed
            baseFeePerGas = $latestBlock.result.baseFeePerGas
        } | Format-List
    }
    else {
        Write-Host $latestBlock.error
    }
}
