import 'dart:async';
import 'dart:io';

import 'package:ftpconnect/src/ftp_unknown_command_exception.dart';

import '../ftp_entry.dart';
import '../ftp_exceptions.dart';
import '../ftp_reply.dart';
import '../ftp_socket.dart';
import '../ftpconnect_base.dart';
import '../utils.dart';

class FTPDirectory {
  final FTPSocket _socket;

  FTPDirectory(this._socket);

  Future<bool> makeDirectory(String sName) async {
    FTPReply sResponse = await (_socket.sendCommand('MKD $sName'));

    return sResponse.isSuccessCode();
  }

  Future<bool> deleteEmptyDirectory(String? sName) async {
    FTPReply sResponse = await (_socket.sendCommand('rmd $sName'));

    return sResponse.isSuccessCode();
  }

  Future<bool> changeDirectory(String? sName) async {
    FTPReply sResponse = await (_socket.sendCommand('CWD $sName'));

    return sResponse.isSuccessCode();
  }

  Future<String> currentDirectory() async {
    FTPReply sResponse = await _socket.sendCommand('PWD');
    if (!sResponse.isSuccessCode()) {
      throw FTPConnectException(
          'Failed to get current working directory', sResponse.message);
    }

    int iStart = sResponse.message.indexOf('"') + 1;
    int iEnd = sResponse.message.lastIndexOf('"');

    return sResponse.message.substring(iStart, iEnd);
  }

  /// List the directory content
  ///
  /// Try to use MLSD or fallback to LIST if the command is unknown
  Future<List<FTPEntry>> directoryContent() async {
    try {
      return await _directoryContent();
    } on FTPUnknownCommandException catch (e) {
      // Try to use the LIST command
      if (_socket.listCommand == ListCommand.MLSD) {
        _socket.listCommand = ListCommand.LIST;
        return await _directoryContent();
      } else
        throw FTPConnectException(e.message);
    }
  }

  Future<List<FTPEntry>> _directoryContent() async {
    // Enter passive mode
    FTPReply response = await _socket.openDataTransferChannel();

    // Directoy content listing, the response will be handled by another socket
    _socket.sendCommandWithoutWaitingResponse(_socket.listCommand.describeEnum);

    // Data transfer socket
    int iPort = Utils.parsePort(response.message, _socket.supportIPV6);

    // dataSocket should be RawSecureSocket if the connection type is FTPS
    RawSocket dataSocket;
    try {
      if (_socket.securityType != SecurityType.FTP) {
        dataSocket = await RawSecureSocket.connect(
          _socket.host,
          iPort,
          timeout: Duration(seconds: _socket.timeout),
          onBadCertificate: (certificate) => true,
        );
      } else {
        dataSocket = await RawSocket.connect(
          _socket.host,
          iPort,
          timeout: Duration(seconds: _socket.timeout),
        );
      }
    } catch (e) {
      throw FTPConnectException(
          'Could not open the data connection to ${_socket.host} ($iPort)',
          e.toString());
    }

    //Test if second socket connection accepted or not
    response = await _socket.readResponse();
    //some server return two lines 125 and 226 for transfer finished
    bool isTransferCompleted = response.isSuccessCode();
    if (!isTransferCompleted && response.code != 125 && response.code != 150) {
      if (response.code == 500) {
        throw FTPUnknownCommandException("Unknown command exception");
      }
      throw FTPConnectException('Connection refused. ', response.message);
    }

    List<int> lstDirectoryListing = [];
    // Listen for data from the server
    await dataSocket.listen((event) {
      switch (event) {
        case RawSocketEvent.read:
          final data = dataSocket.read();
          if (data != null) {
            lstDirectoryListing.addAll(data);
          }
          break;
        case RawSocketEvent.write:
          //dataSocket.write(Utf8Codec().encode('$cmd\r\n'));
          dataSocket.writeEventsEnabled = false;
          break;
        case RawSocketEvent.readClosed:
          dataSocket.close();
          break;
        case RawSocketEvent.closed:
          break;
        default:
          throw "Unexpected event $event";
      }
    }).asFuture();

    if (!isTransferCompleted) {
      response = await _socket.readResponse();
      if (!response.isSuccessCode()) {
        throw FTPConnectException('Transfer Error.', response.message);
      }
    }

    // Convert MLSD response into FTPEntry
    List<FTPEntry> lstFTPEntries = <FTPEntry>[];
    String.fromCharCodes(lstDirectoryListing).split('\n').forEach((line) {
      if (line.trim().isNotEmpty) {
        lstFTPEntries.add(
          FTPEntry.parse(line.replaceAll('\r', ""), _socket.listCommand),
        );
      }
    });

    return lstFTPEntries;
  }

  Future<List<String>> directoryContentNames() async {
    var list = await directoryContent();
    return list.map((f) => f.name).whereType<String>().toList();
  }
}
