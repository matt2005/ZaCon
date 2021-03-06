param()

#Set-StrictMode -Version 2

# extra information
$global:__DEBUG = $false

<##########################################################################
 #   Module:   P/MODEM PowerShell Remoting File Transfer Protocol (PRFTP) #
 #   Author:   Oisin Grehan                                               #
 #   Version:  0.5                                                        #
 #   Date:     October 2009                                               #
 ##########################################################################>

# validate ArgumentList
. {
    param(
        [parameter(Mandatory=$false)]
        [validateset("Tx","Rx")]
        [string]$Mode
    )
} @args

#
#
#

if ($PSVersionTable.PModemProtocolVersion) {
    $PSVersionTable.remove("PModemProtocolVersion")
}
$PSVersionTable.add("PModemProtocolVersion", [version]"0.5")
$global:__pmodemTransfers = @{}

$executioncontext.sessionstate.module.onremove = {
    $psversiontable.remove("PModemProtocolVersion")
    $global:__pmodemTransfers = $null
}

#
# Return protocol version
#

function Get-PModemVersion {
    $PSVersionTable.PModemProtocolVersion
}

#
# Server TX function - imported into caller's session by Get-RemoteFile
#

function Start-FileTransfer {
    param(
        [parameter(mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath, # file on remote computer
        
        [parameter(mandatory=$true, position=1)]
        [ValidateNotNullOrEmpty()]
        [string]$SavePath,
        
        [parameter(mandatory=$true, Position=2)]
        [guid]$TransferId,
        
        [parameter(mandatory=$true, position=3)]
        [int]$PacketSize,
                
        [parameter()]
        [switch]$AsJob # Not implemented
    )

    # just in case someone gets silly.
    if (-not $PSSenderInfo) {
        write-warning "This function should not be invoked in the local session."
        return
    }
    
    if ($AsJob) {
        write-warning "-AsJob functionality is not yet implemented."
        return
    }
    
    $packetId = "PModemPacket_$TransferId"
    
    # Forward events (packets) to implicit remoting client
    Register-EngineEvent -SourceIdentifier $packetId -Forward
    
    try {
        
        if (-not (Test-Path -LiteralPath $LiteralPath)) {
            write-warning "Remote file $LiteralPath does not exist."
            return
        }
        
        # TODO: multiple files, compression
        
        [int]$flags = 1 # TODO: implement handshake, cancel, abort etc?
        
        [int]$length = $(get-item -LiteralPath $LiteralPath).Length
        $stream = [io.file]::OpenRead($LiteralPath)
        
        try {
            $position = 0
            $sequence = 0
            $activityId = 1
            $activity =  "Receiving {0} from {1}" -f [io.path]::getfilename($LiteralPath), $env:computername
                        
            [byte[]]$buffer = new-object byte[] $PacketSize
            
            while ($true) {
                
                $count = $stream.Read($buffer, 0, $packetSize)
                
                if ($count -eq 0) {
                    break;
                }
                
                $position += $count                

                $packet = @{
                    Flags = $flags;
                    Ver   = Get-PModemVersion;
                    Seq   = $sequence;
                    Size  = $count;
                    Data  = $buffer
                }

                # raise event with packet                
                New-Event -SourceIdentifier $packetId -EventArguments $packet -MessageData @($transferId, $savePath) > $null
                
                $sequence++;
                
                # send progress record back to client
                $status = "{0} byte(s) of {1}" -f $position, $length
                $percent = ($position / $length) * 100
                
                Write-Progress -Id $activityId -Activity $activity -Status $status -PercentComplete $percent                
            }
                        
            # completed
            Write-Progress -id $activityId -Activity $activity -Status "Complete" -Completed
            New-Event -SourceIdentifier $packetId -EventArguments @{
                Flags=$flags;
                Ver=Get-PModemVersion;
                Seq=$sequence;
                Size=0;
                Data=$null} -MessageData @($transferId, $savePath) > $null
            
        } finally {
            if ($stream) {
                $stream.Close()
                $stream.Dispose()
            }
        }
    } finally {
        Unregister-Event -SourceIdentifier $packetId
    }
}

#
# Pull file from remote server.
#

function Get-RemoteFile {
<#
    .SYNOPSIS
    Retrieves a file from a remote computer via a supplied PSession. 
    
    .DESCRIPTION
    Retrieves a remote file from a server via a supplied PSSession. All communication
    is performed out-of-band, yet inside the secure WinRM channel. 
    
    No other ports, file shares or any other special configuration is needed. However,
    the PMODEM module must be on the remote computer and findable in its $ENV:PSModulePath;
    the protocol versions must also match on both ends. You will be warned of any
    misconfiguration(s).
    
    When not running asynchronously, progress records are generated.
    
    .EXAMPLE
    
    ps> $s = new-pssession -computer server1
    ps> get-remotefile $s c:\remote\file.exe c:\local\    
    
    .PARAMETER Session
    An open and available PSSession instance to a remote computer.
    
    .PARAMETER RemoteFile
    The location of the file on the remote computer, e.g. c:\logs\foo.log
    
    .PARAMETER LocalPath
    A folder to save the retrieved file. If omitted, the current directory is used.
    
    .PARAMETER PacketSize
    The size of the data packet to use when transferring a file. The default is 512KB.
    
    .PARAMETER PassThru
    Causes the function to emit a FileInfo to the pipeline of the retrieved file.
    
    .PARAMETER AsJob
    Perform the retrieval as a local background job (not implemented.)
    
    .INPUTS
    This function is not yet configured for pipeline input.
    
    .OUTPUTS
    If -PassThrug is set, a System.IO.FileInfo representing the retrieved file is output to the pipeline.
#>
    param(        
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNull()]        
        [Management.Automation.Runspaces.PSSession]$Session,
        
        [parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]$RemoteFile,
        
        [parameter(Position=2)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalPath = ".",
        
        [parameter(position=3)]
        [ValidateRange(1KB, 1MB)]
        [int]$PacketSize = 512KB,
        
        [parameter()]
        [switch]$PassThru,

        [parameter()]
        [switch]$AsJob
    )
    
    # validate supplied pssession
    if (($Session.State -ne "Opened") -or ($Session.Availability -ne "Available")) {
        write-warning "Supplied PSSession is not valid. Must be Opened and Available."
        return
    }
    
    $fileName  = [io.path]::GetFileName($RemoteFile)
    $localFile = [io.path]::Combine($LocalPath, $fileName)
    
    # ensure local folder exists
    if (-not (test-path -LiteralPath $LocalPath -PathType Container)) {
        write-warning "Folder $LocalPath does not exist."
        return
    }
    
    # prevent clobbering of local file
    if ((test-path -LiteralPath $localfile -PathType Leaf)) {
        write-warning "File $localFile already exists."
        return
    }

    $activity =  "Receiving {0} from {1}" -f $fileName, $session.computername

    try {        
        write-progress -id 1 -activity $activity -status "Setting up remote session..."
        
        $erroractionpreference = "Stop" # convert errors to terminating (exceptions)
        
        # load our pmodem module into remote session in TX mode (transmit)
        $remoteVersion = Invoke-Command -Session $session { rmo pmodem -ea 0; ipmo pmodem -args tx; get-pmodemversion }
        
        write-progress -id 1 -activity $activity -status $("PModem protocol ({0}) initialized on remote server..." -f $remoteVersion)
        
        if (-not ($remoteVersion -eq (Get-PModemVersion))) {
            write-warning ("Protocol mismatch: server is {0}; client is {1}." -f $remoteVersion, (Get-PModemVersion))
            return
        }
        
    } catch {
        write-warning "Module PModem not found in `$env:PSModulePath on remote server; please install and try again: $($_)"
        return
    }
    finally {
        $erroractionpreference = "Continue"
    }
    
    # import Start-FileTransfer as Send-RemoteFile from remote session (prefix avoids collision in this module)
    $imported = Import-PSSession -Session $session -CommandName Start-FileTransfer -CommandType Function -Module PModem -Prefix Remote
    write-progress -id 1 -activity $activity -status "Initiating transfer..."
    
    try {

        $transferId = Register-PacketListener
        
        # will block and emit progress records unless specified as job
        Start-RemoteFileTransfer -LiteralPath $RemoteFile -SavePath $LocalFile -TransferId $transferId -PacketSize $PacketSize -AsJob:$AsJob

    } finally {
    
        # cleanup        
        Remove-Module $imported
    }
    
    if ($PassThru -and (test-path $localfile)) {
        get-item $localfile
    }
}

#
# Push file to remote server.
#

function Send-LocalFile {
    <#
        (help)
    #>
    write-warning "Not implemented."
}

#
# Create a packet listener for a specific transferId
#

function Register-PacketListener {
    [cmdletbinding()]
    param()
    
    $transferId = [guid]::NewGuid()
    $packetId = "PModemPacket_$transferId"
    $self = $ExecutionContext.SessionState.Module
    
    Register-EngineEvent -SourceIdentifier $packetId -Action {
        
        function cleanup($transferId) {
            
            $stream.Close()
            $stream.Dispose()
            
            $global:__pmodemTransfers.Remove($transferId)
        
            Unregister-Event -SourceIdentifier $event.SourceIdentifier
        }
        
        if ($event.MessageData) {        
            $transferId, $savePath = $event.MessageData
        }
                
        try {
            $packet = $event.sourceargs[0] # array            
            $stream = $global:__pmodemTransfers[$transferId]            
            
            if (-not $stream) {
                if ($__DEBUG) {
                    write-host "Opening stream for $SavePath"
                }
                
                $stream = [io.file]::OpenWrite($SavePath)
                $global:__pmodemTransfers[$transferId] = $stream
            }
            
            # unpack
            [int]$flags, [int]$sequence, [int]$size, [byte[]]$data = $packet.Flags, $packet.Seq, $packet.Size, $packet.Data
            
            if ($__DEBUG) {
                write-host "Received packet: flags $flags ; seq: $sequence ; size $size"
            }
            
            if ($size -gt 0) {
            
                $stream.write($data, 0, $size)
            
            } else {
                
                # complete
                cleanup $transferId
                
                if ($__DEBUG) {
                    write-host "Completed."
                }
            }
            
        } catch {
        
            write-warning "$transferId - Could not unpack: $_"
            write-warning "cleaning up..."
            
            try { cleanup $transferId; rm -force $savepath } catch {}
        }
    
    } > $null
    
    # return transfer id
    $transferId
}

#
# Not used (yet)
#

function Unregister-PacketListener {
    param(
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$TransferId
    )
    $packetId = "PModemPacket_$transferId"
        
    Get-Event -SourceIdentifier $packetId | Remove-Event
    Unregister-Event $packetId
}

# TODO: use manifests?
switch ($Mode) {
    "Tx" {
        # server mode: transmit
        Export-ModuleMember Start-FileTransfer, Get-PModemVersion
    }
    "Rx" {
        # server mode: receive
        write-warning "Not implemented."
    }
    default {
        # client mode
        Export-ModuleMember Get-RemoteFile, Send-LocalFile
    }    
}
