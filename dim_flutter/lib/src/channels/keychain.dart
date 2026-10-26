
import 'package:dim_client/common.dart';
import 'package:dim_client/ok.dart';

import 'manager.dart';

/// Keychain for iOS, macOS
class KeychainChannel extends SafeChannel implements PrivateKeyDBI {
  KeychainChannel(super.name);

  //
  //  Invoke Methods
  //

  @override
  Future<bool> savePrivateKey(PrivateKey key, String type, ID user,
      {int sign = 1, required int decrypt}) async {
    int? res = await invoke(ChannelMethods.savePrivateKey, {
      'user': user.toString(),
      'type': type,
      'key': key.toMap(),
    });
    return res == 1;
  }

  @override
  Future<PrivateKey?> getPrivateKeyForSignature(ID user) async {
    Map? key = await invoke(ChannelMethods.privateKeyForSignature, {
      'user': user.toString(),
    });
    return _parsePrivateKey(key);
  }

  @override
  Future<PrivateKey?> getPrivateKeyForVisaSignature(ID user) async {
    Map? key = await invoke(ChannelMethods.privateKeyForVisaSignature, {
      'user': user.toString(),
    });
    return _parsePrivateKey(key);
  }

  @override
  Future<List<DecryptKey>> getPrivateKeysForDecryption(ID user) async {
    List? keys = await invoke(ChannelMethods.privateKeysForDecryption, {
      'user': user.toString(),
    });
    if (keys == null || keys.isEmpty) {
      return [];
    }
    List<PrivateKey> privateKeys = [];
    PrivateKey? sk;
    for (var item in keys) {
      sk = _parsePrivateKey(item);
      if (sk == null) {
        assert(false, 'private key error: $item');
        continue;
      }
      privateKeys.add(sk);
    }
    return PrivateKeyDBI.convertDecryptKeys(privateKeys);
  }

}


PrivateKey? _parsePrivateKey(Object? key) {
  if (key == null) {
    return null;
  }
  try {
    // MethodChannel decodes maps as Map<dynamic,dynamic>,
    // which fails DIMP's Dictionary debug assertion (requires Map<String,dynamic>);
    // convert the key map before parsing.
    Map<String, dynamic> info = Map<String, dynamic>.from(key as Map);
    return PrivateKey.parse(info);
  } catch (e, st) {
    Log.error('private key error: $key');
    Log.error('private key error: $e, $st');
    return null;
  }
}
