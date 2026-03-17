// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'wallet.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$AddressInfo {
  String get address => throw _privateConstructorUsedError;
  bool get hasTransparent => throw _privateConstructorUsedError;
  bool get hasSapling => throw _privateConstructorUsedError;
  bool get hasOrchard => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $AddressInfoCopyWith<AddressInfo> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AddressInfoCopyWith<$Res> {
  factory $AddressInfoCopyWith(
          AddressInfo value, $Res Function(AddressInfo) then) =
      _$AddressInfoCopyWithImpl<$Res, AddressInfo>;
  @useResult
  $Res call(
      {String address, bool hasTransparent, bool hasSapling, bool hasOrchard});
}

/// @nodoc
class _$AddressInfoCopyWithImpl<$Res, $Val extends AddressInfo>
    implements $AddressInfoCopyWith<$Res> {
  _$AddressInfoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? hasTransparent = null,
    Object? hasSapling = null,
    Object? hasOrchard = null,
  }) {
    return _then(_value.copyWith(
      address: null == address
          ? _value.address
          : address // ignore: cast_nullable_to_non_nullable
              as String,
      hasTransparent: null == hasTransparent
          ? _value.hasTransparent
          : hasTransparent // ignore: cast_nullable_to_non_nullable
              as bool,
      hasSapling: null == hasSapling
          ? _value.hasSapling
          : hasSapling // ignore: cast_nullable_to_non_nullable
              as bool,
      hasOrchard: null == hasOrchard
          ? _value.hasOrchard
          : hasOrchard // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AddressInfoImplCopyWith<$Res>
    implements $AddressInfoCopyWith<$Res> {
  factory _$$AddressInfoImplCopyWith(
          _$AddressInfoImpl value, $Res Function(_$AddressInfoImpl) then) =
      __$$AddressInfoImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String address, bool hasTransparent, bool hasSapling, bool hasOrchard});
}

/// @nodoc
class __$$AddressInfoImplCopyWithImpl<$Res>
    extends _$AddressInfoCopyWithImpl<$Res, _$AddressInfoImpl>
    implements _$$AddressInfoImplCopyWith<$Res> {
  __$$AddressInfoImplCopyWithImpl(
      _$AddressInfoImpl _value, $Res Function(_$AddressInfoImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? hasTransparent = null,
    Object? hasSapling = null,
    Object? hasOrchard = null,
  }) {
    return _then(_$AddressInfoImpl(
      address: null == address
          ? _value.address
          : address // ignore: cast_nullable_to_non_nullable
              as String,
      hasTransparent: null == hasTransparent
          ? _value.hasTransparent
          : hasTransparent // ignore: cast_nullable_to_non_nullable
              as bool,
      hasSapling: null == hasSapling
          ? _value.hasSapling
          : hasSapling // ignore: cast_nullable_to_non_nullable
              as bool,
      hasOrchard: null == hasOrchard
          ? _value.hasOrchard
          : hasOrchard // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$AddressInfoImpl implements _AddressInfo {
  const _$AddressInfoImpl(
      {required this.address,
      required this.hasTransparent,
      required this.hasSapling,
      required this.hasOrchard});

  @override
  final String address;
  @override
  final bool hasTransparent;
  @override
  final bool hasSapling;
  @override
  final bool hasOrchard;

  @override
  String toString() {
    return 'AddressInfo(address: $address, hasTransparent: $hasTransparent, hasSapling: $hasSapling, hasOrchard: $hasOrchard)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AddressInfoImpl &&
            (identical(other.address, address) || other.address == address) &&
            (identical(other.hasTransparent, hasTransparent) ||
                other.hasTransparent == hasTransparent) &&
            (identical(other.hasSapling, hasSapling) ||
                other.hasSapling == hasSapling) &&
            (identical(other.hasOrchard, hasOrchard) ||
                other.hasOrchard == hasOrchard));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, address, hasTransparent, hasSapling, hasOrchard);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AddressInfoImplCopyWith<_$AddressInfoImpl> get copyWith =>
      __$$AddressInfoImplCopyWithImpl<_$AddressInfoImpl>(this, _$identity);
}

abstract class _AddressInfo implements AddressInfo {
  const factory _AddressInfo(
      {required final String address,
      required final bool hasTransparent,
      required final bool hasSapling,
      required final bool hasOrchard}) = _$AddressInfoImpl;

  @override
  String get address;
  @override
  bool get hasTransparent;
  @override
  bool get hasSapling;
  @override
  bool get hasOrchard;
  @override
  @JsonKey(ignore: true)
  _$$AddressInfoImplCopyWith<_$AddressInfoImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$AddressValidation {
  bool get isValid => throw _privateConstructorUsedError;
  String? get addressType => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $AddressValidationCopyWith<AddressValidation> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AddressValidationCopyWith<$Res> {
  factory $AddressValidationCopyWith(
          AddressValidation value, $Res Function(AddressValidation) then) =
      _$AddressValidationCopyWithImpl<$Res, AddressValidation>;
  @useResult
  $Res call({bool isValid, String? addressType});
}

/// @nodoc
class _$AddressValidationCopyWithImpl<$Res, $Val extends AddressValidation>
    implements $AddressValidationCopyWith<$Res> {
  _$AddressValidationCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isValid = null,
    Object? addressType = freezed,
  }) {
    return _then(_value.copyWith(
      isValid: null == isValid
          ? _value.isValid
          : isValid // ignore: cast_nullable_to_non_nullable
              as bool,
      addressType: freezed == addressType
          ? _value.addressType
          : addressType // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AddressValidationImplCopyWith<$Res>
    implements $AddressValidationCopyWith<$Res> {
  factory _$$AddressValidationImplCopyWith(_$AddressValidationImpl value,
          $Res Function(_$AddressValidationImpl) then) =
      __$$AddressValidationImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({bool isValid, String? addressType});
}

/// @nodoc
class __$$AddressValidationImplCopyWithImpl<$Res>
    extends _$AddressValidationCopyWithImpl<$Res, _$AddressValidationImpl>
    implements _$$AddressValidationImplCopyWith<$Res> {
  __$$AddressValidationImplCopyWithImpl(_$AddressValidationImpl _value,
      $Res Function(_$AddressValidationImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isValid = null,
    Object? addressType = freezed,
  }) {
    return _then(_$AddressValidationImpl(
      isValid: null == isValid
          ? _value.isValid
          : isValid // ignore: cast_nullable_to_non_nullable
              as bool,
      addressType: freezed == addressType
          ? _value.addressType
          : addressType // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$AddressValidationImpl implements _AddressValidation {
  const _$AddressValidationImpl({required this.isValid, this.addressType});

  @override
  final bool isValid;
  @override
  final String? addressType;

  @override
  String toString() {
    return 'AddressValidation(isValid: $isValid, addressType: $addressType)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AddressValidationImpl &&
            (identical(other.isValid, isValid) || other.isValid == isValid) &&
            (identical(other.addressType, addressType) ||
                other.addressType == addressType));
  }

  @override
  int get hashCode => Object.hash(runtimeType, isValid, addressType);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AddressValidationImplCopyWith<_$AddressValidationImpl> get copyWith =>
      __$$AddressValidationImplCopyWithImpl<_$AddressValidationImpl>(
          this, _$identity);
}

abstract class _AddressValidation implements AddressValidation {
  const factory _AddressValidation(
      {required final bool isValid,
      final String? addressType}) = _$AddressValidationImpl;

  @override
  bool get isValid;
  @override
  String? get addressType;
  @override
  @JsonKey(ignore: true)
  _$$AddressValidationImplCopyWith<_$AddressValidationImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$PaymentRecipient {
  String get address => throw _privateConstructorUsedError;
  BigInt get amount => throw _privateConstructorUsedError;
  String? get memo => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $PaymentRecipientCopyWith<PaymentRecipient> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $PaymentRecipientCopyWith<$Res> {
  factory $PaymentRecipientCopyWith(
          PaymentRecipient value, $Res Function(PaymentRecipient) then) =
      _$PaymentRecipientCopyWithImpl<$Res, PaymentRecipient>;
  @useResult
  $Res call({String address, BigInt amount, String? memo});
}

/// @nodoc
class _$PaymentRecipientCopyWithImpl<$Res, $Val extends PaymentRecipient>
    implements $PaymentRecipientCopyWith<$Res> {
  _$PaymentRecipientCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? amount = null,
    Object? memo = freezed,
  }) {
    return _then(_value.copyWith(
      address: null == address
          ? _value.address
          : address // ignore: cast_nullable_to_non_nullable
              as String,
      amount: null == amount
          ? _value.amount
          : amount // ignore: cast_nullable_to_non_nullable
              as BigInt,
      memo: freezed == memo
          ? _value.memo
          : memo // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$PaymentRecipientImplCopyWith<$Res>
    implements $PaymentRecipientCopyWith<$Res> {
  factory _$$PaymentRecipientImplCopyWith(_$PaymentRecipientImpl value,
          $Res Function(_$PaymentRecipientImpl) then) =
      __$$PaymentRecipientImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String address, BigInt amount, String? memo});
}

/// @nodoc
class __$$PaymentRecipientImplCopyWithImpl<$Res>
    extends _$PaymentRecipientCopyWithImpl<$Res, _$PaymentRecipientImpl>
    implements _$$PaymentRecipientImplCopyWith<$Res> {
  __$$PaymentRecipientImplCopyWithImpl(_$PaymentRecipientImpl _value,
      $Res Function(_$PaymentRecipientImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? amount = null,
    Object? memo = freezed,
  }) {
    return _then(_$PaymentRecipientImpl(
      address: null == address
          ? _value.address
          : address // ignore: cast_nullable_to_non_nullable
              as String,
      amount: null == amount
          ? _value.amount
          : amount // ignore: cast_nullable_to_non_nullable
              as BigInt,
      memo: freezed == memo
          ? _value.memo
          : memo // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$PaymentRecipientImpl implements _PaymentRecipient {
  const _$PaymentRecipientImpl(
      {required this.address, required this.amount, this.memo});

  @override
  final String address;
  @override
  final BigInt amount;
  @override
  final String? memo;

  @override
  String toString() {
    return 'PaymentRecipient(address: $address, amount: $amount, memo: $memo)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$PaymentRecipientImpl &&
            (identical(other.address, address) || other.address == address) &&
            (identical(other.amount, amount) || other.amount == amount) &&
            (identical(other.memo, memo) || other.memo == memo));
  }

  @override
  int get hashCode => Object.hash(runtimeType, address, amount, memo);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$PaymentRecipientImplCopyWith<_$PaymentRecipientImpl> get copyWith =>
      __$$PaymentRecipientImplCopyWithImpl<_$PaymentRecipientImpl>(
          this, _$identity);
}

abstract class _PaymentRecipient implements PaymentRecipient {
  const factory _PaymentRecipient(
      {required final String address,
      required final BigInt amount,
      final String? memo}) = _$PaymentRecipientImpl;

  @override
  String get address;
  @override
  BigInt get amount;
  @override
  String? get memo;
  @override
  @JsonKey(ignore: true)
  _$$PaymentRecipientImplCopyWith<_$PaymentRecipientImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$SyncResultInfo {
  int get startHeight => throw _privateConstructorUsedError;
  int get endHeight => throw _privateConstructorUsedError;
  int get blocksScanned => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SyncResultInfoCopyWith<SyncResultInfo> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SyncResultInfoCopyWith<$Res> {
  factory $SyncResultInfoCopyWith(
          SyncResultInfo value, $Res Function(SyncResultInfo) then) =
      _$SyncResultInfoCopyWithImpl<$Res, SyncResultInfo>;
  @useResult
  $Res call({int startHeight, int endHeight, int blocksScanned});
}

/// @nodoc
class _$SyncResultInfoCopyWithImpl<$Res, $Val extends SyncResultInfo>
    implements $SyncResultInfoCopyWith<$Res> {
  _$SyncResultInfoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? startHeight = null,
    Object? endHeight = null,
    Object? blocksScanned = null,
  }) {
    return _then(_value.copyWith(
      startHeight: null == startHeight
          ? _value.startHeight
          : startHeight // ignore: cast_nullable_to_non_nullable
              as int,
      endHeight: null == endHeight
          ? _value.endHeight
          : endHeight // ignore: cast_nullable_to_non_nullable
              as int,
      blocksScanned: null == blocksScanned
          ? _value.blocksScanned
          : blocksScanned // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SyncResultInfoImplCopyWith<$Res>
    implements $SyncResultInfoCopyWith<$Res> {
  factory _$$SyncResultInfoImplCopyWith(_$SyncResultInfoImpl value,
          $Res Function(_$SyncResultInfoImpl) then) =
      __$$SyncResultInfoImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({int startHeight, int endHeight, int blocksScanned});
}

/// @nodoc
class __$$SyncResultInfoImplCopyWithImpl<$Res>
    extends _$SyncResultInfoCopyWithImpl<$Res, _$SyncResultInfoImpl>
    implements _$$SyncResultInfoImplCopyWith<$Res> {
  __$$SyncResultInfoImplCopyWithImpl(
      _$SyncResultInfoImpl _value, $Res Function(_$SyncResultInfoImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? startHeight = null,
    Object? endHeight = null,
    Object? blocksScanned = null,
  }) {
    return _then(_$SyncResultInfoImpl(
      startHeight: null == startHeight
          ? _value.startHeight
          : startHeight // ignore: cast_nullable_to_non_nullable
              as int,
      endHeight: null == endHeight
          ? _value.endHeight
          : endHeight // ignore: cast_nullable_to_non_nullable
              as int,
      blocksScanned: null == blocksScanned
          ? _value.blocksScanned
          : blocksScanned // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class _$SyncResultInfoImpl implements _SyncResultInfo {
  const _$SyncResultInfoImpl(
      {required this.startHeight,
      required this.endHeight,
      required this.blocksScanned});

  @override
  final int startHeight;
  @override
  final int endHeight;
  @override
  final int blocksScanned;

  @override
  String toString() {
    return 'SyncResultInfo(startHeight: $startHeight, endHeight: $endHeight, blocksScanned: $blocksScanned)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SyncResultInfoImpl &&
            (identical(other.startHeight, startHeight) ||
                other.startHeight == startHeight) &&
            (identical(other.endHeight, endHeight) ||
                other.endHeight == endHeight) &&
            (identical(other.blocksScanned, blocksScanned) ||
                other.blocksScanned == blocksScanned));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, startHeight, endHeight, blocksScanned);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SyncResultInfoImplCopyWith<_$SyncResultInfoImpl> get copyWith =>
      __$$SyncResultInfoImplCopyWithImpl<_$SyncResultInfoImpl>(
          this, _$identity);
}

abstract class _SyncResultInfo implements SyncResultInfo {
  const factory _SyncResultInfo(
      {required final int startHeight,
      required final int endHeight,
      required final int blocksScanned}) = _$SyncResultInfoImpl;

  @override
  int get startHeight;
  @override
  int get endHeight;
  @override
  int get blocksScanned;
  @override
  @JsonKey(ignore: true)
  _$$SyncResultInfoImplCopyWith<_$SyncResultInfoImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$SyncStatusInfo {
  String get mode => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SyncStatusInfoCopyWith<SyncStatusInfo> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SyncStatusInfoCopyWith<$Res> {
  factory $SyncStatusInfoCopyWith(
          SyncStatusInfo value, $Res Function(SyncStatusInfo) then) =
      _$SyncStatusInfoCopyWithImpl<$Res, SyncStatusInfo>;
  @useResult
  $Res call({String mode});
}

/// @nodoc
class _$SyncStatusInfoCopyWithImpl<$Res, $Val extends SyncStatusInfo>
    implements $SyncStatusInfoCopyWith<$Res> {
  _$SyncStatusInfoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? mode = null,
  }) {
    return _then(_value.copyWith(
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as String,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SyncStatusInfoImplCopyWith<$Res>
    implements $SyncStatusInfoCopyWith<$Res> {
  factory _$$SyncStatusInfoImplCopyWith(_$SyncStatusInfoImpl value,
          $Res Function(_$SyncStatusInfoImpl) then) =
      __$$SyncStatusInfoImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String mode});
}

/// @nodoc
class __$$SyncStatusInfoImplCopyWithImpl<$Res>
    extends _$SyncStatusInfoCopyWithImpl<$Res, _$SyncStatusInfoImpl>
    implements _$$SyncStatusInfoImplCopyWith<$Res> {
  __$$SyncStatusInfoImplCopyWithImpl(
      _$SyncStatusInfoImpl _value, $Res Function(_$SyncStatusInfoImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? mode = null,
  }) {
    return _then(_$SyncStatusInfoImpl(
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$SyncStatusInfoImpl implements _SyncStatusInfo {
  const _$SyncStatusInfoImpl({required this.mode});

  @override
  final String mode;

  @override
  String toString() {
    return 'SyncStatusInfo(mode: $mode)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SyncStatusInfoImpl &&
            (identical(other.mode, mode) || other.mode == mode));
  }

  @override
  int get hashCode => Object.hash(runtimeType, mode);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SyncStatusInfoImplCopyWith<_$SyncStatusInfoImpl> get copyWith =>
      __$$SyncStatusInfoImplCopyWithImpl<_$SyncStatusInfoImpl>(
          this, _$identity);
}

abstract class _SyncStatusInfo implements SyncStatusInfo {
  const factory _SyncStatusInfo({required final String mode}) =
      _$SyncStatusInfoImpl;

  @override
  String get mode;
  @override
  @JsonKey(ignore: true)
  _$$SyncStatusInfoImplCopyWith<_$SyncStatusInfoImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$TransactionRecord {
  String get txid => throw _privateConstructorUsedError;
  int get height => throw _privateConstructorUsedError;
  BigInt get timestamp => throw _privateConstructorUsedError;
  int get value => throw _privateConstructorUsedError;
  String get kind => throw _privateConstructorUsedError;
  BigInt? get fee => throw _privateConstructorUsedError;
  String get status => throw _privateConstructorUsedError;
  BigInt get rawValue => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $TransactionRecordCopyWith<TransactionRecord> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $TransactionRecordCopyWith<$Res> {
  factory $TransactionRecordCopyWith(
          TransactionRecord value, $Res Function(TransactionRecord) then) =
      _$TransactionRecordCopyWithImpl<$Res, TransactionRecord>;
  @useResult
  $Res call(
      {String txid,
      int height,
      BigInt timestamp,
      int value,
      String kind,
      BigInt? fee,
      String status,
      BigInt rawValue});
}

/// @nodoc
class _$TransactionRecordCopyWithImpl<$Res, $Val extends TransactionRecord>
    implements $TransactionRecordCopyWith<$Res> {
  _$TransactionRecordCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? txid = null,
    Object? height = null,
    Object? timestamp = null,
    Object? value = null,
    Object? kind = null,
    Object? fee = freezed,
    Object? status = null,
    Object? rawValue = null,
  }) {
    return _then(_value.copyWith(
      txid: null == txid
          ? _value.txid
          : txid // ignore: cast_nullable_to_non_nullable
              as String,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as BigInt,
      value: null == value
          ? _value.value
          : value // ignore: cast_nullable_to_non_nullable
              as int,
      kind: null == kind
          ? _value.kind
          : kind // ignore: cast_nullable_to_non_nullable
              as String,
      fee: freezed == fee
          ? _value.fee
          : fee // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
      rawValue: null == rawValue
          ? _value.rawValue
          : rawValue // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$TransactionRecordImplCopyWith<$Res>
    implements $TransactionRecordCopyWith<$Res> {
  factory _$$TransactionRecordImplCopyWith(_$TransactionRecordImpl value,
          $Res Function(_$TransactionRecordImpl) then) =
      __$$TransactionRecordImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String txid,
      int height,
      BigInt timestamp,
      int value,
      String kind,
      BigInt? fee,
      String status,
      BigInt rawValue});
}

/// @nodoc
class __$$TransactionRecordImplCopyWithImpl<$Res>
    extends _$TransactionRecordCopyWithImpl<$Res, _$TransactionRecordImpl>
    implements _$$TransactionRecordImplCopyWith<$Res> {
  __$$TransactionRecordImplCopyWithImpl(_$TransactionRecordImpl _value,
      $Res Function(_$TransactionRecordImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? txid = null,
    Object? height = null,
    Object? timestamp = null,
    Object? value = null,
    Object? kind = null,
    Object? fee = freezed,
    Object? status = null,
    Object? rawValue = null,
  }) {
    return _then(_$TransactionRecordImpl(
      txid: null == txid
          ? _value.txid
          : txid // ignore: cast_nullable_to_non_nullable
              as String,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as BigInt,
      value: null == value
          ? _value.value
          : value // ignore: cast_nullable_to_non_nullable
              as int,
      kind: null == kind
          ? _value.kind
          : kind // ignore: cast_nullable_to_non_nullable
              as String,
      fee: freezed == fee
          ? _value.fee
          : fee // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
      rawValue: null == rawValue
          ? _value.rawValue
          : rawValue // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class _$TransactionRecordImpl implements _TransactionRecord {
  const _$TransactionRecordImpl(
      {required this.txid,
      required this.height,
      required this.timestamp,
      required this.value,
      required this.kind,
      this.fee,
      required this.status,
      required this.rawValue});

  @override
  final String txid;
  @override
  final int height;
  @override
  final BigInt timestamp;
  @override
  final int value;
  @override
  final String kind;
  @override
  final BigInt? fee;
  @override
  final String status;
  @override
  final BigInt rawValue;

  @override
  String toString() {
    return 'TransactionRecord(txid: $txid, height: $height, timestamp: $timestamp, value: $value, kind: $kind, fee: $fee, status: $status, rawValue: $rawValue)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$TransactionRecordImpl &&
            (identical(other.txid, txid) || other.txid == txid) &&
            (identical(other.height, height) || other.height == height) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp) &&
            (identical(other.value, value) || other.value == value) &&
            (identical(other.kind, kind) || other.kind == kind) &&
            (identical(other.fee, fee) || other.fee == fee) &&
            (identical(other.status, status) || other.status == status) &&
            (identical(other.rawValue, rawValue) ||
                other.rawValue == rawValue));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, txid, height, timestamp, value, kind, fee, status, rawValue);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$TransactionRecordImplCopyWith<_$TransactionRecordImpl> get copyWith =>
      __$$TransactionRecordImplCopyWithImpl<_$TransactionRecordImpl>(
          this, _$identity);
}

abstract class _TransactionRecord implements TransactionRecord {
  const factory _TransactionRecord(
      {required final String txid,
      required final int height,
      required final BigInt timestamp,
      required final int value,
      required final String kind,
      final BigInt? fee,
      required final String status,
      required final BigInt rawValue}) = _$TransactionRecordImpl;

  @override
  String get txid;
  @override
  int get height;
  @override
  BigInt get timestamp;
  @override
  int get value;
  @override
  String get kind;
  @override
  BigInt? get fee;
  @override
  String get status;
  @override
  BigInt get rawValue;
  @override
  @JsonKey(ignore: true)
  _$$TransactionRecordImplCopyWith<_$TransactionRecordImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$ValueTransferRecord {
  String get txid => throw _privateConstructorUsedError;
  int get height => throw _privateConstructorUsedError;
  BigInt get timestamp => throw _privateConstructorUsedError;
  BigInt get value => throw _privateConstructorUsedError;
  String get kind => throw _privateConstructorUsedError;
  BigInt? get fee => throw _privateConstructorUsedError;
  String? get recipientAddress => throw _privateConstructorUsedError;
  String? get poolReceived => throw _privateConstructorUsedError;
  List<String> get memos => throw _privateConstructorUsedError;
  String get status => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ValueTransferRecordCopyWith<ValueTransferRecord> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ValueTransferRecordCopyWith<$Res> {
  factory $ValueTransferRecordCopyWith(
          ValueTransferRecord value, $Res Function(ValueTransferRecord) then) =
      _$ValueTransferRecordCopyWithImpl<$Res, ValueTransferRecord>;
  @useResult
  $Res call(
      {String txid,
      int height,
      BigInt timestamp,
      BigInt value,
      String kind,
      BigInt? fee,
      String? recipientAddress,
      String? poolReceived,
      List<String> memos,
      String status});
}

/// @nodoc
class _$ValueTransferRecordCopyWithImpl<$Res, $Val extends ValueTransferRecord>
    implements $ValueTransferRecordCopyWith<$Res> {
  _$ValueTransferRecordCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? txid = null,
    Object? height = null,
    Object? timestamp = null,
    Object? value = null,
    Object? kind = null,
    Object? fee = freezed,
    Object? recipientAddress = freezed,
    Object? poolReceived = freezed,
    Object? memos = null,
    Object? status = null,
  }) {
    return _then(_value.copyWith(
      txid: null == txid
          ? _value.txid
          : txid // ignore: cast_nullable_to_non_nullable
              as String,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as BigInt,
      value: null == value
          ? _value.value
          : value // ignore: cast_nullable_to_non_nullable
              as BigInt,
      kind: null == kind
          ? _value.kind
          : kind // ignore: cast_nullable_to_non_nullable
              as String,
      fee: freezed == fee
          ? _value.fee
          : fee // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      recipientAddress: freezed == recipientAddress
          ? _value.recipientAddress
          : recipientAddress // ignore: cast_nullable_to_non_nullable
              as String?,
      poolReceived: freezed == poolReceived
          ? _value.poolReceived
          : poolReceived // ignore: cast_nullable_to_non_nullable
              as String?,
      memos: null == memos
          ? _value.memos
          : memos // ignore: cast_nullable_to_non_nullable
              as List<String>,
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ValueTransferRecordImplCopyWith<$Res>
    implements $ValueTransferRecordCopyWith<$Res> {
  factory _$$ValueTransferRecordImplCopyWith(_$ValueTransferRecordImpl value,
          $Res Function(_$ValueTransferRecordImpl) then) =
      __$$ValueTransferRecordImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String txid,
      int height,
      BigInt timestamp,
      BigInt value,
      String kind,
      BigInt? fee,
      String? recipientAddress,
      String? poolReceived,
      List<String> memos,
      String status});
}

/// @nodoc
class __$$ValueTransferRecordImplCopyWithImpl<$Res>
    extends _$ValueTransferRecordCopyWithImpl<$Res, _$ValueTransferRecordImpl>
    implements _$$ValueTransferRecordImplCopyWith<$Res> {
  __$$ValueTransferRecordImplCopyWithImpl(_$ValueTransferRecordImpl _value,
      $Res Function(_$ValueTransferRecordImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? txid = null,
    Object? height = null,
    Object? timestamp = null,
    Object? value = null,
    Object? kind = null,
    Object? fee = freezed,
    Object? recipientAddress = freezed,
    Object? poolReceived = freezed,
    Object? memos = null,
    Object? status = null,
  }) {
    return _then(_$ValueTransferRecordImpl(
      txid: null == txid
          ? _value.txid
          : txid // ignore: cast_nullable_to_non_nullable
              as String,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as BigInt,
      value: null == value
          ? _value.value
          : value // ignore: cast_nullable_to_non_nullable
              as BigInt,
      kind: null == kind
          ? _value.kind
          : kind // ignore: cast_nullable_to_non_nullable
              as String,
      fee: freezed == fee
          ? _value.fee
          : fee // ignore: cast_nullable_to_non_nullable
              as BigInt?,
      recipientAddress: freezed == recipientAddress
          ? _value.recipientAddress
          : recipientAddress // ignore: cast_nullable_to_non_nullable
              as String?,
      poolReceived: freezed == poolReceived
          ? _value.poolReceived
          : poolReceived // ignore: cast_nullable_to_non_nullable
              as String?,
      memos: null == memos
          ? _value._memos
          : memos // ignore: cast_nullable_to_non_nullable
              as List<String>,
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$ValueTransferRecordImpl implements _ValueTransferRecord {
  const _$ValueTransferRecordImpl(
      {required this.txid,
      required this.height,
      required this.timestamp,
      required this.value,
      required this.kind,
      this.fee,
      this.recipientAddress,
      this.poolReceived,
      required final List<String> memos,
      required this.status})
      : _memos = memos;

  @override
  final String txid;
  @override
  final int height;
  @override
  final BigInt timestamp;
  @override
  final BigInt value;
  @override
  final String kind;
  @override
  final BigInt? fee;
  @override
  final String? recipientAddress;
  @override
  final String? poolReceived;
  final List<String> _memos;
  @override
  List<String> get memos {
    if (_memos is EqualUnmodifiableListView) return _memos;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_memos);
  }

  @override
  final String status;

  @override
  String toString() {
    return 'ValueTransferRecord(txid: $txid, height: $height, timestamp: $timestamp, value: $value, kind: $kind, fee: $fee, recipientAddress: $recipientAddress, poolReceived: $poolReceived, memos: $memos, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ValueTransferRecordImpl &&
            (identical(other.txid, txid) || other.txid == txid) &&
            (identical(other.height, height) || other.height == height) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp) &&
            (identical(other.value, value) || other.value == value) &&
            (identical(other.kind, kind) || other.kind == kind) &&
            (identical(other.fee, fee) || other.fee == fee) &&
            (identical(other.recipientAddress, recipientAddress) ||
                other.recipientAddress == recipientAddress) &&
            (identical(other.poolReceived, poolReceived) ||
                other.poolReceived == poolReceived) &&
            const DeepCollectionEquality().equals(other._memos, _memos) &&
            (identical(other.status, status) || other.status == status));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      txid,
      height,
      timestamp,
      value,
      kind,
      fee,
      recipientAddress,
      poolReceived,
      const DeepCollectionEquality().hash(_memos),
      status);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ValueTransferRecordImplCopyWith<_$ValueTransferRecordImpl> get copyWith =>
      __$$ValueTransferRecordImplCopyWithImpl<_$ValueTransferRecordImpl>(
          this, _$identity);
}

abstract class _ValueTransferRecord implements ValueTransferRecord {
  const factory _ValueTransferRecord(
      {required final String txid,
      required final int height,
      required final BigInt timestamp,
      required final BigInt value,
      required final String kind,
      final BigInt? fee,
      final String? recipientAddress,
      final String? poolReceived,
      required final List<String> memos,
      required final String status}) = _$ValueTransferRecordImpl;

  @override
  String get txid;
  @override
  int get height;
  @override
  BigInt get timestamp;
  @override
  BigInt get value;
  @override
  String get kind;
  @override
  BigInt? get fee;
  @override
  String? get recipientAddress;
  @override
  String? get poolReceived;
  @override
  List<String> get memos;
  @override
  String get status;
  @override
  @JsonKey(ignore: true)
  _$$ValueTransferRecordImplCopyWith<_$ValueTransferRecordImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
mixin _$WalletBalance {
  BigInt get transparent => throw _privateConstructorUsedError;
  BigInt get sapling => throw _privateConstructorUsedError;
  BigInt get orchard => throw _privateConstructorUsedError;
  BigInt get unconfirmedSapling => throw _privateConstructorUsedError;
  BigInt get unconfirmedOrchard => throw _privateConstructorUsedError;
  BigInt get unconfirmedTransparent => throw _privateConstructorUsedError;
  BigInt get totalTransparent => throw _privateConstructorUsedError;
  BigInt get totalSapling => throw _privateConstructorUsedError;
  BigInt get totalOrchard => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $WalletBalanceCopyWith<WalletBalance> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $WalletBalanceCopyWith<$Res> {
  factory $WalletBalanceCopyWith(
          WalletBalance value, $Res Function(WalletBalance) then) =
      _$WalletBalanceCopyWithImpl<$Res, WalletBalance>;
  @useResult
  $Res call(
      {BigInt transparent,
      BigInt sapling,
      BigInt orchard,
      BigInt unconfirmedSapling,
      BigInt unconfirmedOrchard,
      BigInt unconfirmedTransparent,
      BigInt totalTransparent,
      BigInt totalSapling,
      BigInt totalOrchard});
}

/// @nodoc
class _$WalletBalanceCopyWithImpl<$Res, $Val extends WalletBalance>
    implements $WalletBalanceCopyWith<$Res> {
  _$WalletBalanceCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? transparent = null,
    Object? sapling = null,
    Object? orchard = null,
    Object? unconfirmedSapling = null,
    Object? unconfirmedOrchard = null,
    Object? unconfirmedTransparent = null,
    Object? totalTransparent = null,
    Object? totalSapling = null,
    Object? totalOrchard = null,
  }) {
    return _then(_value.copyWith(
      transparent: null == transparent
          ? _value.transparent
          : transparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      sapling: null == sapling
          ? _value.sapling
          : sapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      orchard: null == orchard
          ? _value.orchard
          : orchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedSapling: null == unconfirmedSapling
          ? _value.unconfirmedSapling
          : unconfirmedSapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedOrchard: null == unconfirmedOrchard
          ? _value.unconfirmedOrchard
          : unconfirmedOrchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedTransparent: null == unconfirmedTransparent
          ? _value.unconfirmedTransparent
          : unconfirmedTransparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalTransparent: null == totalTransparent
          ? _value.totalTransparent
          : totalTransparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalSapling: null == totalSapling
          ? _value.totalSapling
          : totalSapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalOrchard: null == totalOrchard
          ? _value.totalOrchard
          : totalOrchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$WalletBalanceImplCopyWith<$Res>
    implements $WalletBalanceCopyWith<$Res> {
  factory _$$WalletBalanceImplCopyWith(
          _$WalletBalanceImpl value, $Res Function(_$WalletBalanceImpl) then) =
      __$$WalletBalanceImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {BigInt transparent,
      BigInt sapling,
      BigInt orchard,
      BigInt unconfirmedSapling,
      BigInt unconfirmedOrchard,
      BigInt unconfirmedTransparent,
      BigInt totalTransparent,
      BigInt totalSapling,
      BigInt totalOrchard});
}

/// @nodoc
class __$$WalletBalanceImplCopyWithImpl<$Res>
    extends _$WalletBalanceCopyWithImpl<$Res, _$WalletBalanceImpl>
    implements _$$WalletBalanceImplCopyWith<$Res> {
  __$$WalletBalanceImplCopyWithImpl(
      _$WalletBalanceImpl _value, $Res Function(_$WalletBalanceImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? transparent = null,
    Object? sapling = null,
    Object? orchard = null,
    Object? unconfirmedSapling = null,
    Object? unconfirmedOrchard = null,
    Object? unconfirmedTransparent = null,
    Object? totalTransparent = null,
    Object? totalSapling = null,
    Object? totalOrchard = null,
  }) {
    return _then(_$WalletBalanceImpl(
      transparent: null == transparent
          ? _value.transparent
          : transparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      sapling: null == sapling
          ? _value.sapling
          : sapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      orchard: null == orchard
          ? _value.orchard
          : orchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedSapling: null == unconfirmedSapling
          ? _value.unconfirmedSapling
          : unconfirmedSapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedOrchard: null == unconfirmedOrchard
          ? _value.unconfirmedOrchard
          : unconfirmedOrchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
      unconfirmedTransparent: null == unconfirmedTransparent
          ? _value.unconfirmedTransparent
          : unconfirmedTransparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalTransparent: null == totalTransparent
          ? _value.totalTransparent
          : totalTransparent // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalSapling: null == totalSapling
          ? _value.totalSapling
          : totalSapling // ignore: cast_nullable_to_non_nullable
              as BigInt,
      totalOrchard: null == totalOrchard
          ? _value.totalOrchard
          : totalOrchard // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class _$WalletBalanceImpl extends _WalletBalance {
  const _$WalletBalanceImpl(
      {required this.transparent,
      required this.sapling,
      required this.orchard,
      required this.unconfirmedSapling,
      required this.unconfirmedOrchard,
      required this.unconfirmedTransparent,
      required this.totalTransparent,
      required this.totalSapling,
      required this.totalOrchard})
      : super._();

  @override
  final BigInt transparent;
  @override
  final BigInt sapling;
  @override
  final BigInt orchard;
  @override
  final BigInt unconfirmedSapling;
  @override
  final BigInt unconfirmedOrchard;
  @override
  final BigInt unconfirmedTransparent;
  @override
  final BigInt totalTransparent;
  @override
  final BigInt totalSapling;
  @override
  final BigInt totalOrchard;

  @override
  String toString() {
    return 'WalletBalance(transparent: $transparent, sapling: $sapling, orchard: $orchard, unconfirmedSapling: $unconfirmedSapling, unconfirmedOrchard: $unconfirmedOrchard, unconfirmedTransparent: $unconfirmedTransparent, totalTransparent: $totalTransparent, totalSapling: $totalSapling, totalOrchard: $totalOrchard)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$WalletBalanceImpl &&
            (identical(other.transparent, transparent) ||
                other.transparent == transparent) &&
            (identical(other.sapling, sapling) || other.sapling == sapling) &&
            (identical(other.orchard, orchard) || other.orchard == orchard) &&
            (identical(other.unconfirmedSapling, unconfirmedSapling) ||
                other.unconfirmedSapling == unconfirmedSapling) &&
            (identical(other.unconfirmedOrchard, unconfirmedOrchard) ||
                other.unconfirmedOrchard == unconfirmedOrchard) &&
            (identical(other.unconfirmedTransparent, unconfirmedTransparent) ||
                other.unconfirmedTransparent == unconfirmedTransparent) &&
            (identical(other.totalTransparent, totalTransparent) ||
                other.totalTransparent == totalTransparent) &&
            (identical(other.totalSapling, totalSapling) ||
                other.totalSapling == totalSapling) &&
            (identical(other.totalOrchard, totalOrchard) ||
                other.totalOrchard == totalOrchard));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      transparent,
      sapling,
      orchard,
      unconfirmedSapling,
      unconfirmedOrchard,
      unconfirmedTransparent,
      totalTransparent,
      totalSapling,
      totalOrchard);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$WalletBalanceImplCopyWith<_$WalletBalanceImpl> get copyWith =>
      __$$WalletBalanceImplCopyWithImpl<_$WalletBalanceImpl>(this, _$identity);
}

abstract class _WalletBalance extends WalletBalance {
  const factory _WalletBalance(
      {required final BigInt transparent,
      required final BigInt sapling,
      required final BigInt orchard,
      required final BigInt unconfirmedSapling,
      required final BigInt unconfirmedOrchard,
      required final BigInt unconfirmedTransparent,
      required final BigInt totalTransparent,
      required final BigInt totalSapling,
      required final BigInt totalOrchard}) = _$WalletBalanceImpl;
  const _WalletBalance._() : super._();

  @override
  BigInt get transparent;
  @override
  BigInt get sapling;
  @override
  BigInt get orchard;
  @override
  BigInt get unconfirmedSapling;
  @override
  BigInt get unconfirmedOrchard;
  @override
  BigInt get unconfirmedTransparent;
  @override
  BigInt get totalTransparent;
  @override
  BigInt get totalSapling;
  @override
  BigInt get totalOrchard;
  @override
  @JsonKey(ignore: true)
  _$$WalletBalanceImplCopyWith<_$WalletBalanceImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
