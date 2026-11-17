// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $TimetableEntriesTable extends TimetableEntries
    with TableInfo<$TimetableEntriesTable, TimetableEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TimetableEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _weekdayMeta = const VerificationMeta(
    'weekday',
  );
  @override
  late final GeneratedColumn<int> weekday = GeneratedColumn<int>(
    'weekday',
    aliasedName,
    false,
    check: () => ComparableExpr(weekday).isBetweenValues(1, 7),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startTimeMeta = const VerificationMeta(
    'startTime',
  );
  @override
  late final GeneratedColumn<String> startTime = GeneratedColumn<String>(
    'start_time',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endTimeMeta = const VerificationMeta(
    'endTime',
  );
  @override
  late final GeneratedColumn<String> endTime = GeneratedColumn<String>(
    'end_time',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _locationMeta = const VerificationMeta(
    'location',
  );
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
    'location',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    weekday,
    startTime,
    endTime,
    title,
    location,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'timetable_entry';
  @override
  VerificationContext validateIntegrity(
    Insertable<TimetableEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('weekday')) {
      context.handle(
        _weekdayMeta,
        weekday.isAcceptableOrUnknown(data['weekday']!, _weekdayMeta),
      );
    } else if (isInserting) {
      context.missing(_weekdayMeta);
    }
    if (data.containsKey('start_time')) {
      context.handle(
        _startTimeMeta,
        startTime.isAcceptableOrUnknown(data['start_time']!, _startTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_startTimeMeta);
    }
    if (data.containsKey('end_time')) {
      context.handle(
        _endTimeMeta,
        endTime.isAcceptableOrUnknown(data['end_time']!, _endTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_endTimeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('location')) {
      context.handle(
        _locationMeta,
        location.isAcceptableOrUnknown(data['location']!, _locationMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TimetableEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TimetableEntryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      weekday: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weekday'],
      )!,
      startTime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start_time'],
      )!,
      endTime: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_time'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      location: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $TimetableEntriesTable createAlias(String alias) {
    return $TimetableEntriesTable(attachedDatabase, alias);
  }
}

class TimetableEntryRow extends DataClass
    implements Insertable<TimetableEntryRow> {
  final String id;
  final int weekday;
  final String startTime;
  final String endTime;
  final String title;
  final String? location;
  final String createdAt;
  final String updatedAt;
  const TimetableEntryRow({
    required this.id,
    required this.weekday,
    required this.startTime,
    required this.endTime,
    required this.title,
    this.location,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['weekday'] = Variable<int>(weekday);
    map['start_time'] = Variable<String>(startTime);
    map['end_time'] = Variable<String>(endTime);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || location != null) {
      map['location'] = Variable<String>(location);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  TimetableEntriesCompanion toCompanion(bool nullToAbsent) {
    return TimetableEntriesCompanion(
      id: Value(id),
      weekday: Value(weekday),
      startTime: Value(startTime),
      endTime: Value(endTime),
      title: Value(title),
      location: location == null && nullToAbsent
          ? const Value.absent()
          : Value(location),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory TimetableEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TimetableEntryRow(
      id: serializer.fromJson<String>(json['id']),
      weekday: serializer.fromJson<int>(json['weekday']),
      startTime: serializer.fromJson<String>(json['startTime']),
      endTime: serializer.fromJson<String>(json['endTime']),
      title: serializer.fromJson<String>(json['title']),
      location: serializer.fromJson<String?>(json['location']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'weekday': serializer.toJson<int>(weekday),
      'startTime': serializer.toJson<String>(startTime),
      'endTime': serializer.toJson<String>(endTime),
      'title': serializer.toJson<String>(title),
      'location': serializer.toJson<String?>(location),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  TimetableEntryRow copyWith({
    String? id,
    int? weekday,
    String? startTime,
    String? endTime,
    String? title,
    Value<String?> location = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => TimetableEntryRow(
    id: id ?? this.id,
    weekday: weekday ?? this.weekday,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    title: title ?? this.title,
    location: location.present ? location.value : this.location,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  TimetableEntryRow copyWithCompanion(TimetableEntriesCompanion data) {
    return TimetableEntryRow(
      id: data.id.present ? data.id.value : this.id,
      weekday: data.weekday.present ? data.weekday.value : this.weekday,
      startTime: data.startTime.present ? data.startTime.value : this.startTime,
      endTime: data.endTime.present ? data.endTime.value : this.endTime,
      title: data.title.present ? data.title.value : this.title,
      location: data.location.present ? data.location.value : this.location,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TimetableEntryRow(')
          ..write('id: $id, ')
          ..write('weekday: $weekday, ')
          ..write('startTime: $startTime, ')
          ..write('endTime: $endTime, ')
          ..write('title: $title, ')
          ..write('location: $location, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    weekday,
    startTime,
    endTime,
    title,
    location,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TimetableEntryRow &&
          other.id == this.id &&
          other.weekday == this.weekday &&
          other.startTime == this.startTime &&
          other.endTime == this.endTime &&
          other.title == this.title &&
          other.location == this.location &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class TimetableEntriesCompanion extends UpdateCompanion<TimetableEntryRow> {
  final Value<String> id;
  final Value<int> weekday;
  final Value<String> startTime;
  final Value<String> endTime;
  final Value<String> title;
  final Value<String?> location;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const TimetableEntriesCompanion({
    this.id = const Value.absent(),
    this.weekday = const Value.absent(),
    this.startTime = const Value.absent(),
    this.endTime = const Value.absent(),
    this.title = const Value.absent(),
    this.location = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TimetableEntriesCompanion.insert({
    required String id,
    required int weekday,
    required String startTime,
    required String endTime,
    required String title,
    this.location = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       weekday = Value(weekday),
       startTime = Value(startTime),
       endTime = Value(endTime),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TimetableEntryRow> custom({
    Expression<String>? id,
    Expression<int>? weekday,
    Expression<String>? startTime,
    Expression<String>? endTime,
    Expression<String>? title,
    Expression<String>? location,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (weekday != null) 'weekday': weekday,
      if (startTime != null) 'start_time': startTime,
      if (endTime != null) 'end_time': endTime,
      if (title != null) 'title': title,
      if (location != null) 'location': location,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TimetableEntriesCompanion copyWith({
    Value<String>? id,
    Value<int>? weekday,
    Value<String>? startTime,
    Value<String>? endTime,
    Value<String>? title,
    Value<String?>? location,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return TimetableEntriesCompanion(
      id: id ?? this.id,
      weekday: weekday ?? this.weekday,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      title: title ?? this.title,
      location: location ?? this.location,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (weekday.present) {
      map['weekday'] = Variable<int>(weekday.value);
    }
    if (startTime.present) {
      map['start_time'] = Variable<String>(startTime.value);
    }
    if (endTime.present) {
      map['end_time'] = Variable<String>(endTime.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TimetableEntriesCompanion(')
          ..write('id: $id, ')
          ..write('weekday: $weekday, ')
          ..write('startTime: $startTime, ')
          ..write('endTime: $endTime, ')
          ..write('title: $title, ')
          ..write('location: $location, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppMetaTable extends AppMeta with TableInfo<$AppMetaTable, AppMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AppMetaTable createAlias(String alias) {
    return $AppMetaTable(attachedDatabase, alias);
  }
}

class AppMetaRow extends DataClass implements Insertable<AppMetaRow> {
  final String key;
  final String value;
  final String updatedAt;
  const AppMetaRow({
    required this.key,
    required this.value,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  AppMetaCompanion toCompanion(bool nullToAbsent) {
    return AppMetaCompanion(
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory AppMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  AppMetaRow copyWith({String? key, String? value, String? updatedAt}) =>
      AppMetaRow(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  AppMetaRow copyWithCompanion(AppMetaCompanion data) {
    return AppMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppMetaRow &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class AppMetaCompanion extends UpdateCompanion<AppMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const AppMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppMetaCompanion.insert({
    required String key,
    required String value,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value),
       updatedAt = Value(updatedAt);
  static Insertable<AppMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return AppMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfilesTable extends Profiles
    with TableInfo<$ProfilesTable, ProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    check: () => id.equals(1),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dayCutoffHourMeta = const VerificationMeta(
    'dayCutoffHour',
  );
  @override
  late final GeneratedColumn<int> dayCutoffHour = GeneratedColumn<int>(
    'day_cutoff_hour',
    aliasedName,
    false,
    check: () => ComparableExpr(dayCutoffHour).isBetweenValues(0, 6),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(4),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    dayCutoffHour,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProfileRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('day_cutoff_hour')) {
      context.handle(
        _dayCutoffHourMeta,
        dayCutoffHour.isAcceptableOrUnknown(
          data['day_cutoff_hour']!,
          _dayCutoffHourMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      dayCutoffHour: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}day_cutoff_hour'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class ProfileRow extends DataClass implements Insertable<ProfileRow> {
  final int id;
  final int dayCutoffHour;
  final String createdAt;
  final String updatedAt;
  const ProfileRow({
    required this.id,
    required this.dayCutoffHour,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['day_cutoff_hour'] = Variable<int>(dayCutoffHour);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      dayCutoffHour: Value(dayCutoffHour),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ProfileRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileRow(
      id: serializer.fromJson<int>(json['id']),
      dayCutoffHour: serializer.fromJson<int>(json['dayCutoffHour']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'dayCutoffHour': serializer.toJson<int>(dayCutoffHour),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  ProfileRow copyWith({
    int? id,
    int? dayCutoffHour,
    String? createdAt,
    String? updatedAt,
  }) => ProfileRow(
    id: id ?? this.id,
    dayCutoffHour: dayCutoffHour ?? this.dayCutoffHour,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ProfileRow copyWithCompanion(ProfilesCompanion data) {
    return ProfileRow(
      id: data.id.present ? data.id.value : this.id,
      dayCutoffHour: data.dayCutoffHour.present
          ? data.dayCutoffHour.value
          : this.dayCutoffHour,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileRow(')
          ..write('id: $id, ')
          ..write('dayCutoffHour: $dayCutoffHour, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, dayCutoffHour, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileRow &&
          other.id == this.id &&
          other.dayCutoffHour == this.dayCutoffHour &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ProfilesCompanion extends UpdateCompanion<ProfileRow> {
  final Value<int> id;
  final Value<int> dayCutoffHour;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.dayCutoffHour = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ProfilesCompanion.insert({
    this.id = const Value.absent(),
    this.dayCutoffHour = const Value.absent(),
    required String createdAt,
    required String updatedAt,
  }) : createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ProfileRow> custom({
    Expression<int>? id,
    Expression<int>? dayCutoffHour,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dayCutoffHour != null) 'day_cutoff_hour': dayCutoffHour,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ProfilesCompanion copyWith({
    Value<int>? id,
    Value<int>? dayCutoffHour,
    Value<String>? createdAt,
    Value<String>? updatedAt,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      dayCutoffHour: dayCutoffHour ?? this.dayCutoffHour,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (dayCutoffHour.present) {
      map['day_cutoff_hour'] = Variable<int>(dayCutoffHour.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('dayCutoffHour: $dayCutoffHour, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $LearningGoalsTable extends LearningGoals
    with TableInfo<$LearningGoalsTable, LearningGoalRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LearningGoalsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeTextMeta = const VerificationMeta(
    'scopeText',
  );
  @override
  late final GeneratedColumn<String> scopeText = GeneratedColumn<String>(
    'scope_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueDateMeta = const VerificationMeta(
    'dueDate',
  );
  @override
  late final GeneratedColumn<String> dueDate = GeneratedColumn<String>(
    'due_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(learningGoalStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    scopeText,
    dueDate,
    status,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'learning_goal';
  @override
  VerificationContext validateIntegrity(
    Insertable<LearningGoalRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('scope_text')) {
      context.handle(
        _scopeTextMeta,
        scopeText.isAcceptableOrUnknown(data['scope_text']!, _scopeTextMeta),
      );
    }
    if (data.containsKey('due_date')) {
      context.handle(
        _dueDateMeta,
        dueDate.isAcceptableOrUnknown(data['due_date']!, _dueDateMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LearningGoalRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LearningGoalRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      scopeText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_text'],
      ),
      dueDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}due_date'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LearningGoalsTable createAlias(String alias) {
    return $LearningGoalsTable(attachedDatabase, alias);
  }
}

class LearningGoalRow extends DataClass implements Insertable<LearningGoalRow> {
  final String id;
  final String title;
  final String? scopeText;
  final String? dueDate;
  final String status;
  final String createdAt;
  final String updatedAt;
  const LearningGoalRow({
    required this.id,
    required this.title,
    this.scopeText,
    this.dueDate,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || scopeText != null) {
      map['scope_text'] = Variable<String>(scopeText);
    }
    if (!nullToAbsent || dueDate != null) {
      map['due_date'] = Variable<String>(dueDate);
    }
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  LearningGoalsCompanion toCompanion(bool nullToAbsent) {
    return LearningGoalsCompanion(
      id: Value(id),
      title: Value(title),
      scopeText: scopeText == null && nullToAbsent
          ? const Value.absent()
          : Value(scopeText),
      dueDate: dueDate == null && nullToAbsent
          ? const Value.absent()
          : Value(dueDate),
      status: Value(status),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory LearningGoalRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LearningGoalRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      scopeText: serializer.fromJson<String?>(json['scopeText']),
      dueDate: serializer.fromJson<String?>(json['dueDate']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'scopeText': serializer.toJson<String?>(scopeText),
      'dueDate': serializer.toJson<String?>(dueDate),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  LearningGoalRow copyWith({
    String? id,
    String? title,
    Value<String?> scopeText = const Value.absent(),
    Value<String?> dueDate = const Value.absent(),
    String? status,
    String? createdAt,
    String? updatedAt,
  }) => LearningGoalRow(
    id: id ?? this.id,
    title: title ?? this.title,
    scopeText: scopeText.present ? scopeText.value : this.scopeText,
    dueDate: dueDate.present ? dueDate.value : this.dueDate,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LearningGoalRow copyWithCompanion(LearningGoalsCompanion data) {
    return LearningGoalRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      scopeText: data.scopeText.present ? data.scopeText.value : this.scopeText,
      dueDate: data.dueDate.present ? data.dueDate.value : this.dueDate,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LearningGoalRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('scopeText: $scopeText, ')
          ..write('dueDate: $dueDate, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, title, scopeText, dueDate, status, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LearningGoalRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.scopeText == this.scopeText &&
          other.dueDate == this.dueDate &&
          other.status == this.status &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class LearningGoalsCompanion extends UpdateCompanion<LearningGoalRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String?> scopeText;
  final Value<String?> dueDate;
  final Value<String> status;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const LearningGoalsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.scopeText = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LearningGoalsCompanion.insert({
    required String id,
    required String title,
    this.scopeText = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.status = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<LearningGoalRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? scopeText,
    Expression<String>? dueDate,
    Expression<String>? status,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (scopeText != null) 'scope_text': scopeText,
      if (dueDate != null) 'due_date': dueDate,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LearningGoalsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? scopeText,
    Value<String?>? dueDate,
    Value<String>? status,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return LearningGoalsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      scopeText: scopeText ?? this.scopeText,
      dueDate: dueDate ?? this.dueDate,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (scopeText.present) {
      map['scope_text'] = Variable<String>(scopeText.value);
    }
    if (dueDate.present) {
      map['due_date'] = Variable<String>(dueDate.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LearningGoalsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('scopeText: $scopeText, ')
          ..write('dueDate: $dueDate, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AssetObjectsTable extends AssetObjects
    with TableInfo<$AssetObjectsTable, AssetObjectRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AssetObjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _hashMeta = const VerificationMeta('hash');
  @override
  late final GeneratedColumn<String> hash = GeneratedColumn<String>(
    'hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _byteLengthMeta = const VerificationMeta(
    'byteLength',
  );
  @override
  late final GeneratedColumn<int> byteLength = GeneratedColumn<int>(
    'byte_length',
    aliasedName,
    false,
    check: () => ComparableExpr(byteLength).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [hash, byteLength, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'asset_object';
  @override
  VerificationContext validateIntegrity(
    Insertable<AssetObjectRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('hash')) {
      context.handle(
        _hashMeta,
        hash.isAcceptableOrUnknown(data['hash']!, _hashMeta),
      );
    } else if (isInserting) {
      context.missing(_hashMeta);
    }
    if (data.containsKey('byte_length')) {
      context.handle(
        _byteLengthMeta,
        byteLength.isAcceptableOrUnknown(data['byte_length']!, _byteLengthMeta),
      );
    } else if (isInserting) {
      context.missing(_byteLengthMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {hash};
  @override
  AssetObjectRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AssetObjectRow(
      hash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hash'],
      )!,
      byteLength: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}byte_length'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $AssetObjectsTable createAlias(String alias) {
    return $AssetObjectsTable(attachedDatabase, alias);
  }
}

class AssetObjectRow extends DataClass implements Insertable<AssetObjectRow> {
  final String hash;
  final int byteLength;
  final String createdAt;
  const AssetObjectRow({
    required this.hash,
    required this.byteLength,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['hash'] = Variable<String>(hash);
    map['byte_length'] = Variable<int>(byteLength);
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  AssetObjectsCompanion toCompanion(bool nullToAbsent) {
    return AssetObjectsCompanion(
      hash: Value(hash),
      byteLength: Value(byteLength),
      createdAt: Value(createdAt),
    );
  }

  factory AssetObjectRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AssetObjectRow(
      hash: serializer.fromJson<String>(json['hash']),
      byteLength: serializer.fromJson<int>(json['byteLength']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'hash': serializer.toJson<String>(hash),
      'byteLength': serializer.toJson<int>(byteLength),
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  AssetObjectRow copyWith({String? hash, int? byteLength, String? createdAt}) =>
      AssetObjectRow(
        hash: hash ?? this.hash,
        byteLength: byteLength ?? this.byteLength,
        createdAt: createdAt ?? this.createdAt,
      );
  AssetObjectRow copyWithCompanion(AssetObjectsCompanion data) {
    return AssetObjectRow(
      hash: data.hash.present ? data.hash.value : this.hash,
      byteLength: data.byteLength.present
          ? data.byteLength.value
          : this.byteLength,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AssetObjectRow(')
          ..write('hash: $hash, ')
          ..write('byteLength: $byteLength, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(hash, byteLength, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AssetObjectRow &&
          other.hash == this.hash &&
          other.byteLength == this.byteLength &&
          other.createdAt == this.createdAt);
}

class AssetObjectsCompanion extends UpdateCompanion<AssetObjectRow> {
  final Value<String> hash;
  final Value<int> byteLength;
  final Value<String> createdAt;
  final Value<int> rowid;
  const AssetObjectsCompanion({
    this.hash = const Value.absent(),
    this.byteLength = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AssetObjectsCompanion.insert({
    required String hash,
    required int byteLength,
    required String createdAt,
    this.rowid = const Value.absent(),
  }) : hash = Value(hash),
       byteLength = Value(byteLength),
       createdAt = Value(createdAt);
  static Insertable<AssetObjectRow> custom({
    Expression<String>? hash,
    Expression<int>? byteLength,
    Expression<String>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (hash != null) 'hash': hash,
      if (byteLength != null) 'byte_length': byteLength,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AssetObjectsCompanion copyWith({
    Value<String>? hash,
    Value<int>? byteLength,
    Value<String>? createdAt,
    Value<int>? rowid,
  }) {
    return AssetObjectsCompanion(
      hash: hash ?? this.hash,
      byteLength: byteLength ?? this.byteLength,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (hash.present) {
      map['hash'] = Variable<String>(hash.value);
    }
    if (byteLength.present) {
      map['byte_length'] = Variable<int>(byteLength.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AssetObjectsCompanion(')
          ..write('hash: $hash, ')
          ..write('byteLength: $byteLength, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AssetChunksTable extends AssetChunks
    with TableInfo<$AssetChunksTable, AssetChunkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AssetChunksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _hashMeta = const VerificationMeta('hash');
  @override
  late final GeneratedColumn<String> hash = GeneratedColumn<String>(
    'hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES asset_object (hash) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    check: () => ComparableExpr(seq).isBiggerOrEqualValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [hash, seq, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'asset_chunk';
  @override
  VerificationContext validateIntegrity(
    Insertable<AssetChunkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('hash')) {
      context.handle(
        _hashMeta,
        hash.isAcceptableOrUnknown(data['hash']!, _hashMeta),
      );
    } else if (isInserting) {
      context.missing(_hashMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {hash, seq};
  @override
  AssetChunkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AssetChunkRow(
      hash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hash'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      )!,
    );
  }

  @override
  $AssetChunksTable createAlias(String alias) {
    return $AssetChunksTable(attachedDatabase, alias);
  }
}

class AssetChunkRow extends DataClass implements Insertable<AssetChunkRow> {
  final String hash;
  final int seq;
  final Uint8List data;
  const AssetChunkRow({
    required this.hash,
    required this.seq,
    required this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['hash'] = Variable<String>(hash);
    map['seq'] = Variable<int>(seq);
    map['data'] = Variable<Uint8List>(data);
    return map;
  }

  AssetChunksCompanion toCompanion(bool nullToAbsent) {
    return AssetChunksCompanion(
      hash: Value(hash),
      seq: Value(seq),
      data: Value(data),
    );
  }

  factory AssetChunkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AssetChunkRow(
      hash: serializer.fromJson<String>(json['hash']),
      seq: serializer.fromJson<int>(json['seq']),
      data: serializer.fromJson<Uint8List>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'hash': serializer.toJson<String>(hash),
      'seq': serializer.toJson<int>(seq),
      'data': serializer.toJson<Uint8List>(data),
    };
  }

  AssetChunkRow copyWith({String? hash, int? seq, Uint8List? data}) =>
      AssetChunkRow(
        hash: hash ?? this.hash,
        seq: seq ?? this.seq,
        data: data ?? this.data,
      );
  AssetChunkRow copyWithCompanion(AssetChunksCompanion data) {
    return AssetChunkRow(
      hash: data.hash.present ? data.hash.value : this.hash,
      seq: data.seq.present ? data.seq.value : this.seq,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AssetChunkRow(')
          ..write('hash: $hash, ')
          ..write('seq: $seq, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(hash, seq, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AssetChunkRow &&
          other.hash == this.hash &&
          other.seq == this.seq &&
          $driftBlobEquality.equals(other.data, this.data));
}

class AssetChunksCompanion extends UpdateCompanion<AssetChunkRow> {
  final Value<String> hash;
  final Value<int> seq;
  final Value<Uint8List> data;
  final Value<int> rowid;
  const AssetChunksCompanion({
    this.hash = const Value.absent(),
    this.seq = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AssetChunksCompanion.insert({
    required String hash,
    required int seq,
    required Uint8List data,
    this.rowid = const Value.absent(),
  }) : hash = Value(hash),
       seq = Value(seq),
       data = Value(data);
  static Insertable<AssetChunkRow> custom({
    Expression<String>? hash,
    Expression<int>? seq,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (hash != null) 'hash': hash,
      if (seq != null) 'seq': seq,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AssetChunksCompanion copyWith({
    Value<String>? hash,
    Value<int>? seq,
    Value<Uint8List>? data,
    Value<int>? rowid,
  }) {
    return AssetChunksCompanion(
      hash: hash ?? this.hash,
      seq: seq ?? this.seq,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (hash.present) {
      map['hash'] = Variable<String>(hash.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AssetChunksCompanion(')
          ..write('hash: $hash, ')
          ..write('seq: $seq, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MaterialsTable extends Materials
    with TableInfo<$MaterialsTable, MaterialRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MaterialsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    check: () => kind.isIn(materialKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('text'),
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceFileNameMeta = const VerificationMeta(
    'sourceFileName',
  );
  @override
  late final GeneratedColumn<String> sourceFileName = GeneratedColumn<String>(
    'source_file_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceFileHashMeta = const VerificationMeta(
    'sourceFileHash',
  );
  @override
  late final GeneratedColumn<String> sourceFileHash = GeneratedColumn<String>(
    'source_file_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES asset_object (hash)',
    ),
  );
  static const VerificationMeta _goalIdMeta = const VerificationMeta('goalId');
  @override
  late final GeneratedColumn<String> goalId = GeneratedColumn<String>(
    'goal_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES learning_goal (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    kind,
    sourceRef,
    sourceFileName,
    sourceFileHash,
    goalId,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'material';
  @override
  VerificationContext validateIntegrity(
    Insertable<MaterialRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('source_file_name')) {
      context.handle(
        _sourceFileNameMeta,
        sourceFileName.isAcceptableOrUnknown(
          data['source_file_name']!,
          _sourceFileNameMeta,
        ),
      );
    }
    if (data.containsKey('source_file_hash')) {
      context.handle(
        _sourceFileHashMeta,
        sourceFileHash.isAcceptableOrUnknown(
          data['source_file_hash']!,
          _sourceFileHashMeta,
        ),
      );
    }
    if (data.containsKey('goal_id')) {
      context.handle(
        _goalIdMeta,
        goalId.isAcceptableOrUnknown(data['goal_id']!, _goalIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MaterialRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MaterialRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      sourceFileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_file_name'],
      ),
      sourceFileHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_file_hash'],
      ),
      goalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}goal_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MaterialsTable createAlias(String alias) {
    return $MaterialsTable(attachedDatabase, alias);
  }
}

class MaterialRow extends DataClass implements Insertable<MaterialRow> {
  final String id;
  final String title;
  final String kind;
  final String? sourceRef;
  final String? sourceFileName;
  final String? sourceFileHash;
  final String? goalId;
  final String createdAt;
  final String updatedAt;
  const MaterialRow({
    required this.id,
    required this.title,
    required this.kind,
    this.sourceRef,
    this.sourceFileName,
    this.sourceFileHash,
    this.goalId,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    if (!nullToAbsent || sourceFileName != null) {
      map['source_file_name'] = Variable<String>(sourceFileName);
    }
    if (!nullToAbsent || sourceFileHash != null) {
      map['source_file_hash'] = Variable<String>(sourceFileHash);
    }
    if (!nullToAbsent || goalId != null) {
      map['goal_id'] = Variable<String>(goalId);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  MaterialsCompanion toCompanion(bool nullToAbsent) {
    return MaterialsCompanion(
      id: Value(id),
      title: Value(title),
      kind: Value(kind),
      sourceRef: sourceRef == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceRef),
      sourceFileName: sourceFileName == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceFileName),
      sourceFileHash: sourceFileHash == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceFileHash),
      goalId: goalId == null && nullToAbsent
          ? const Value.absent()
          : Value(goalId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory MaterialRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MaterialRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      kind: serializer.fromJson<String>(json['kind']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      sourceFileName: serializer.fromJson<String?>(json['sourceFileName']),
      sourceFileHash: serializer.fromJson<String?>(json['sourceFileHash']),
      goalId: serializer.fromJson<String?>(json['goalId']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'kind': serializer.toJson<String>(kind),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'sourceFileName': serializer.toJson<String?>(sourceFileName),
      'sourceFileHash': serializer.toJson<String?>(sourceFileHash),
      'goalId': serializer.toJson<String?>(goalId),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  MaterialRow copyWith({
    String? id,
    String? title,
    String? kind,
    Value<String?> sourceRef = const Value.absent(),
    Value<String?> sourceFileName = const Value.absent(),
    Value<String?> sourceFileHash = const Value.absent(),
    Value<String?> goalId = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => MaterialRow(
    id: id ?? this.id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    sourceFileName: sourceFileName.present
        ? sourceFileName.value
        : this.sourceFileName,
    sourceFileHash: sourceFileHash.present
        ? sourceFileHash.value
        : this.sourceFileHash,
    goalId: goalId.present ? goalId.value : this.goalId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MaterialRow copyWithCompanion(MaterialsCompanion data) {
    return MaterialRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      kind: data.kind.present ? data.kind.value : this.kind,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      sourceFileName: data.sourceFileName.present
          ? data.sourceFileName.value
          : this.sourceFileName,
      sourceFileHash: data.sourceFileHash.present
          ? data.sourceFileHash.value
          : this.sourceFileHash,
      goalId: data.goalId.present ? data.goalId.value : this.goalId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MaterialRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('kind: $kind, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('sourceFileName: $sourceFileName, ')
          ..write('sourceFileHash: $sourceFileHash, ')
          ..write('goalId: $goalId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    kind,
    sourceRef,
    sourceFileName,
    sourceFileHash,
    goalId,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MaterialRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.kind == this.kind &&
          other.sourceRef == this.sourceRef &&
          other.sourceFileName == this.sourceFileName &&
          other.sourceFileHash == this.sourceFileHash &&
          other.goalId == this.goalId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class MaterialsCompanion extends UpdateCompanion<MaterialRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> kind;
  final Value<String?> sourceRef;
  final Value<String?> sourceFileName;
  final Value<String?> sourceFileHash;
  final Value<String?> goalId;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const MaterialsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.kind = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.sourceFileName = const Value.absent(),
    this.sourceFileHash = const Value.absent(),
    this.goalId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MaterialsCompanion.insert({
    required String id,
    required String title,
    this.kind = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.sourceFileName = const Value.absent(),
    this.sourceFileHash = const Value.absent(),
    this.goalId = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<MaterialRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? kind,
    Expression<String>? sourceRef,
    Expression<String>? sourceFileName,
    Expression<String>? sourceFileHash,
    Expression<String>? goalId,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (kind != null) 'kind': kind,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (sourceFileName != null) 'source_file_name': sourceFileName,
      if (sourceFileHash != null) 'source_file_hash': sourceFileHash,
      if (goalId != null) 'goal_id': goalId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MaterialsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? kind,
    Value<String?>? sourceRef,
    Value<String?>? sourceFileName,
    Value<String?>? sourceFileHash,
    Value<String?>? goalId,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return MaterialsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      sourceRef: sourceRef ?? this.sourceRef,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      sourceFileHash: sourceFileHash ?? this.sourceFileHash,
      goalId: goalId ?? this.goalId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (sourceFileName.present) {
      map['source_file_name'] = Variable<String>(sourceFileName.value);
    }
    if (sourceFileHash.present) {
      map['source_file_hash'] = Variable<String>(sourceFileHash.value);
    }
    if (goalId.present) {
      map['goal_id'] = Variable<String>(goalId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MaterialsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('kind: $kind, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('sourceFileName: $sourceFileName, ')
          ..write('sourceFileHash: $sourceFileHash, ')
          ..write('goalId: $goalId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MaterialPagesTable extends MaterialPages
    with TableInfo<$MaterialPagesTable, MaterialPageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MaterialPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _materialIdMeta = const VerificationMeta(
    'materialId',
  );
  @override
  late final GeneratedColumn<String> materialId = GeneratedColumn<String>(
    'material_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES material (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _pageNoMeta = const VerificationMeta('pageNo');
  @override
  late final GeneratedColumn<int> pageNo = GeneratedColumn<int>(
    'page_no',
    aliasedName,
    false,
    check: () => ComparableExpr(pageNo).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    materialId,
    pageNo,
    label,
    content,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'material_page';
  @override
  VerificationContext validateIntegrity(
    Insertable<MaterialPageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('material_id')) {
      context.handle(
        _materialIdMeta,
        materialId.isAcceptableOrUnknown(data['material_id']!, _materialIdMeta),
      );
    } else if (isInserting) {
      context.missing(_materialIdMeta);
    }
    if (data.containsKey('page_no')) {
      context.handle(
        _pageNoMeta,
        pageNo.isAcceptableOrUnknown(data['page_no']!, _pageNoMeta),
      );
    } else if (isInserting) {
      context.missing(_pageNoMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {materialId, pageNo},
  ];
  @override
  MaterialPageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MaterialPageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      materialId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}material_id'],
      )!,
      pageNo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_no'],
      )!,
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      ),
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MaterialPagesTable createAlias(String alias) {
    return $MaterialPagesTable(attachedDatabase, alias);
  }
}

class MaterialPageRow extends DataClass implements Insertable<MaterialPageRow> {
  final String id;
  final String materialId;
  final int pageNo;
  final String? label;
  final String content;
  final String createdAt;
  final String updatedAt;
  const MaterialPageRow({
    required this.id,
    required this.materialId,
    required this.pageNo,
    this.label,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['material_id'] = Variable<String>(materialId);
    map['page_no'] = Variable<int>(pageNo);
    if (!nullToAbsent || label != null) {
      map['label'] = Variable<String>(label);
    }
    map['content'] = Variable<String>(content);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  MaterialPagesCompanion toCompanion(bool nullToAbsent) {
    return MaterialPagesCompanion(
      id: Value(id),
      materialId: Value(materialId),
      pageNo: Value(pageNo),
      label: label == null && nullToAbsent
          ? const Value.absent()
          : Value(label),
      content: Value(content),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory MaterialPageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MaterialPageRow(
      id: serializer.fromJson<String>(json['id']),
      materialId: serializer.fromJson<String>(json['materialId']),
      pageNo: serializer.fromJson<int>(json['pageNo']),
      label: serializer.fromJson<String?>(json['label']),
      content: serializer.fromJson<String>(json['content']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'materialId': serializer.toJson<String>(materialId),
      'pageNo': serializer.toJson<int>(pageNo),
      'label': serializer.toJson<String?>(label),
      'content': serializer.toJson<String>(content),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  MaterialPageRow copyWith({
    String? id,
    String? materialId,
    int? pageNo,
    Value<String?> label = const Value.absent(),
    String? content,
    String? createdAt,
    String? updatedAt,
  }) => MaterialPageRow(
    id: id ?? this.id,
    materialId: materialId ?? this.materialId,
    pageNo: pageNo ?? this.pageNo,
    label: label.present ? label.value : this.label,
    content: content ?? this.content,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MaterialPageRow copyWithCompanion(MaterialPagesCompanion data) {
    return MaterialPageRow(
      id: data.id.present ? data.id.value : this.id,
      materialId: data.materialId.present
          ? data.materialId.value
          : this.materialId,
      pageNo: data.pageNo.present ? data.pageNo.value : this.pageNo,
      label: data.label.present ? data.label.value : this.label,
      content: data.content.present ? data.content.value : this.content,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MaterialPageRow(')
          ..write('id: $id, ')
          ..write('materialId: $materialId, ')
          ..write('pageNo: $pageNo, ')
          ..write('label: $label, ')
          ..write('content: $content, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, materialId, pageNo, label, content, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MaterialPageRow &&
          other.id == this.id &&
          other.materialId == this.materialId &&
          other.pageNo == this.pageNo &&
          other.label == this.label &&
          other.content == this.content &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class MaterialPagesCompanion extends UpdateCompanion<MaterialPageRow> {
  final Value<String> id;
  final Value<String> materialId;
  final Value<int> pageNo;
  final Value<String?> label;
  final Value<String> content;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const MaterialPagesCompanion({
    this.id = const Value.absent(),
    this.materialId = const Value.absent(),
    this.pageNo = const Value.absent(),
    this.label = const Value.absent(),
    this.content = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MaterialPagesCompanion.insert({
    required String id,
    required String materialId,
    required int pageNo,
    this.label = const Value.absent(),
    required String content,
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       materialId = Value(materialId),
       pageNo = Value(pageNo),
       content = Value(content),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<MaterialPageRow> custom({
    Expression<String>? id,
    Expression<String>? materialId,
    Expression<int>? pageNo,
    Expression<String>? label,
    Expression<String>? content,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (materialId != null) 'material_id': materialId,
      if (pageNo != null) 'page_no': pageNo,
      if (label != null) 'label': label,
      if (content != null) 'content': content,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MaterialPagesCompanion copyWith({
    Value<String>? id,
    Value<String>? materialId,
    Value<int>? pageNo,
    Value<String?>? label,
    Value<String>? content,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return MaterialPagesCompanion(
      id: id ?? this.id,
      materialId: materialId ?? this.materialId,
      pageNo: pageNo ?? this.pageNo,
      label: label ?? this.label,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (materialId.present) {
      map['material_id'] = Variable<String>(materialId.value);
    }
    if (pageNo.present) {
      map['page_no'] = Variable<int>(pageNo.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MaterialPagesCompanion(')
          ..write('id: $id, ')
          ..write('materialId: $materialId, ')
          ..write('pageNo: $pageNo, ')
          ..write('label: $label, ')
          ..write('content: $content, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _goalIdMeta = const VerificationMeta('goalId');
  @override
  late final GeneratedColumn<String> goalId = GeneratedColumn<String>(
    'goal_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES learning_goal (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _materialIdMeta = const VerificationMeta(
    'materialId',
  );
  @override
  late final GeneratedColumn<String> materialId = GeneratedColumn<String>(
    'material_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES material (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _pageNoMeta = const VerificationMeta('pageNo');
  @override
  late final GeneratedColumn<int> pageNo = GeneratedColumn<int>(
    'page_no',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contextTextMeta = const VerificationMeta(
    'contextText',
  );
  @override
  late final GeneratedColumn<String> contextText = GeneratedColumn<String>(
    'context_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _questionMessageIdMeta = const VerificationMeta(
    'questionMessageId',
  );
  @override
  late final GeneratedColumn<String> questionMessageId =
      GeneratedColumn<String>(
        'question_message_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _entryKindMeta = const VerificationMeta(
    'entryKind',
  );
  @override
  late final GeneratedColumn<String> entryKind = GeneratedColumn<String>(
    'entry_kind',
    aliasedName,
    false,
    check: () => entryKind.isIn(entryKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('text'),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(conversationStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('open'),
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<String> endedAt = GeneratedColumn<String>(
    'ended_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastMessageAtMeta = const VerificationMeta(
    'lastMessageAt',
  );
  @override
  late final GeneratedColumn<String> lastMessageAt = GeneratedColumn<String>(
    'last_message_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    goalId,
    materialId,
    pageNo,
    sourceRef,
    contextText,
    questionMessageId,
    entryKind,
    status,
    endedAt,
    lastMessageAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('goal_id')) {
      context.handle(
        _goalIdMeta,
        goalId.isAcceptableOrUnknown(data['goal_id']!, _goalIdMeta),
      );
    }
    if (data.containsKey('material_id')) {
      context.handle(
        _materialIdMeta,
        materialId.isAcceptableOrUnknown(data['material_id']!, _materialIdMeta),
      );
    }
    if (data.containsKey('page_no')) {
      context.handle(
        _pageNoMeta,
        pageNo.isAcceptableOrUnknown(data['page_no']!, _pageNoMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('context_text')) {
      context.handle(
        _contextTextMeta,
        contextText.isAcceptableOrUnknown(
          data['context_text']!,
          _contextTextMeta,
        ),
      );
    }
    if (data.containsKey('question_message_id')) {
      context.handle(
        _questionMessageIdMeta,
        questionMessageId.isAcceptableOrUnknown(
          data['question_message_id']!,
          _questionMessageIdMeta,
        ),
      );
    }
    if (data.containsKey('entry_kind')) {
      context.handle(
        _entryKindMeta,
        entryKind.isAcceptableOrUnknown(data['entry_kind']!, _entryKindMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    }
    if (data.containsKey('last_message_at')) {
      context.handle(
        _lastMessageAtMeta,
        lastMessageAt.isAcceptableOrUnknown(
          data['last_message_at']!,
          _lastMessageAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      goalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}goal_id'],
      ),
      materialId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}material_id'],
      ),
      pageNo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_no'],
      ),
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      contextText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}context_text'],
      ),
      questionMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_message_id'],
      ),
      entryKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry_kind'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ended_at'],
      ),
      lastMessageAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_message_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;
  final String? title;
  final String? goalId;
  final String? materialId;
  final int? pageNo;
  final String? sourceRef;
  final String? contextText;
  final String? questionMessageId;
  final String entryKind;
  final String status;
  final String? endedAt;
  final String? lastMessageAt;
  final String createdAt;
  final String updatedAt;
  const ConversationRow({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.sourceRef,
    this.contextText,
    this.questionMessageId,
    required this.entryKind,
    required this.status,
    this.endedAt,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || goalId != null) {
      map['goal_id'] = Variable<String>(goalId);
    }
    if (!nullToAbsent || materialId != null) {
      map['material_id'] = Variable<String>(materialId);
    }
    if (!nullToAbsent || pageNo != null) {
      map['page_no'] = Variable<int>(pageNo);
    }
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    if (!nullToAbsent || contextText != null) {
      map['context_text'] = Variable<String>(contextText);
    }
    if (!nullToAbsent || questionMessageId != null) {
      map['question_message_id'] = Variable<String>(questionMessageId);
    }
    map['entry_kind'] = Variable<String>(entryKind);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || endedAt != null) {
      map['ended_at'] = Variable<String>(endedAt);
    }
    if (!nullToAbsent || lastMessageAt != null) {
      map['last_message_at'] = Variable<String>(lastMessageAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      goalId: goalId == null && nullToAbsent
          ? const Value.absent()
          : Value(goalId),
      materialId: materialId == null && nullToAbsent
          ? const Value.absent()
          : Value(materialId),
      pageNo: pageNo == null && nullToAbsent
          ? const Value.absent()
          : Value(pageNo),
      sourceRef: sourceRef == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceRef),
      contextText: contextText == null && nullToAbsent
          ? const Value.absent()
          : Value(contextText),
      questionMessageId: questionMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(questionMessageId),
      entryKind: Value(entryKind),
      status: Value(status),
      endedAt: endedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAt),
      lastMessageAt: lastMessageAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String?>(json['title']),
      goalId: serializer.fromJson<String?>(json['goalId']),
      materialId: serializer.fromJson<String?>(json['materialId']),
      pageNo: serializer.fromJson<int?>(json['pageNo']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      contextText: serializer.fromJson<String?>(json['contextText']),
      questionMessageId: serializer.fromJson<String?>(
        json['questionMessageId'],
      ),
      entryKind: serializer.fromJson<String>(json['entryKind']),
      status: serializer.fromJson<String>(json['status']),
      endedAt: serializer.fromJson<String?>(json['endedAt']),
      lastMessageAt: serializer.fromJson<String?>(json['lastMessageAt']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String?>(title),
      'goalId': serializer.toJson<String?>(goalId),
      'materialId': serializer.toJson<String?>(materialId),
      'pageNo': serializer.toJson<int?>(pageNo),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'contextText': serializer.toJson<String?>(contextText),
      'questionMessageId': serializer.toJson<String?>(questionMessageId),
      'entryKind': serializer.toJson<String>(entryKind),
      'status': serializer.toJson<String>(status),
      'endedAt': serializer.toJson<String?>(endedAt),
      'lastMessageAt': serializer.toJson<String?>(lastMessageAt),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  ConversationRow copyWith({
    String? id,
    Value<String?> title = const Value.absent(),
    Value<String?> goalId = const Value.absent(),
    Value<String?> materialId = const Value.absent(),
    Value<int?> pageNo = const Value.absent(),
    Value<String?> sourceRef = const Value.absent(),
    Value<String?> contextText = const Value.absent(),
    Value<String?> questionMessageId = const Value.absent(),
    String? entryKind,
    String? status,
    Value<String?> endedAt = const Value.absent(),
    Value<String?> lastMessageAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => ConversationRow(
    id: id ?? this.id,
    title: title.present ? title.value : this.title,
    goalId: goalId.present ? goalId.value : this.goalId,
    materialId: materialId.present ? materialId.value : this.materialId,
    pageNo: pageNo.present ? pageNo.value : this.pageNo,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    contextText: contextText.present ? contextText.value : this.contextText,
    questionMessageId: questionMessageId.present
        ? questionMessageId.value
        : this.questionMessageId,
    entryKind: entryKind ?? this.entryKind,
    status: status ?? this.status,
    endedAt: endedAt.present ? endedAt.value : this.endedAt,
    lastMessageAt: lastMessageAt.present
        ? lastMessageAt.value
        : this.lastMessageAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ConversationRow copyWithCompanion(ConversationsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      goalId: data.goalId.present ? data.goalId.value : this.goalId,
      materialId: data.materialId.present
          ? data.materialId.value
          : this.materialId,
      pageNo: data.pageNo.present ? data.pageNo.value : this.pageNo,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      contextText: data.contextText.present
          ? data.contextText.value
          : this.contextText,
      questionMessageId: data.questionMessageId.present
          ? data.questionMessageId.value
          : this.questionMessageId,
      entryKind: data.entryKind.present ? data.entryKind.value : this.entryKind,
      status: data.status.present ? data.status.value : this.status,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      lastMessageAt: data.lastMessageAt.present
          ? data.lastMessageAt.value
          : this.lastMessageAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('goalId: $goalId, ')
          ..write('materialId: $materialId, ')
          ..write('pageNo: $pageNo, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('contextText: $contextText, ')
          ..write('questionMessageId: $questionMessageId, ')
          ..write('entryKind: $entryKind, ')
          ..write('status: $status, ')
          ..write('endedAt: $endedAt, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    goalId,
    materialId,
    pageNo,
    sourceRef,
    contextText,
    questionMessageId,
    entryKind,
    status,
    endedAt,
    lastMessageAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.goalId == this.goalId &&
          other.materialId == this.materialId &&
          other.pageNo == this.pageNo &&
          other.sourceRef == this.sourceRef &&
          other.contextText == this.contextText &&
          other.questionMessageId == this.questionMessageId &&
          other.entryKind == this.entryKind &&
          other.status == this.status &&
          other.endedAt == this.endedAt &&
          other.lastMessageAt == this.lastMessageAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String?> title;
  final Value<String?> goalId;
  final Value<String?> materialId;
  final Value<int?> pageNo;
  final Value<String?> sourceRef;
  final Value<String?> contextText;
  final Value<String?> questionMessageId;
  final Value<String> entryKind;
  final Value<String> status;
  final Value<String?> endedAt;
  final Value<String?> lastMessageAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.goalId = const Value.absent(),
    this.materialId = const Value.absent(),
    this.pageNo = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.contextText = const Value.absent(),
    this.questionMessageId = const Value.absent(),
    this.entryKind = const Value.absent(),
    this.status = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.lastMessageAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    this.title = const Value.absent(),
    this.goalId = const Value.absent(),
    this.materialId = const Value.absent(),
    this.pageNo = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.contextText = const Value.absent(),
    this.questionMessageId = const Value.absent(),
    this.entryKind = const Value.absent(),
    this.status = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.lastMessageAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? goalId,
    Expression<String>? materialId,
    Expression<int>? pageNo,
    Expression<String>? sourceRef,
    Expression<String>? contextText,
    Expression<String>? questionMessageId,
    Expression<String>? entryKind,
    Expression<String>? status,
    Expression<String>? endedAt,
    Expression<String>? lastMessageAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (goalId != null) 'goal_id': goalId,
      if (materialId != null) 'material_id': materialId,
      if (pageNo != null) 'page_no': pageNo,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (contextText != null) 'context_text': contextText,
      if (questionMessageId != null) 'question_message_id': questionMessageId,
      if (entryKind != null) 'entry_kind': entryKind,
      if (status != null) 'status': status,
      if (endedAt != null) 'ended_at': endedAt,
      if (lastMessageAt != null) 'last_message_at': lastMessageAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String?>? title,
    Value<String?>? goalId,
    Value<String?>? materialId,
    Value<int?>? pageNo,
    Value<String?>? sourceRef,
    Value<String?>? contextText,
    Value<String?>? questionMessageId,
    Value<String>? entryKind,
    Value<String>? status,
    Value<String?>? endedAt,
    Value<String?>? lastMessageAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      goalId: goalId ?? this.goalId,
      materialId: materialId ?? this.materialId,
      pageNo: pageNo ?? this.pageNo,
      sourceRef: sourceRef ?? this.sourceRef,
      contextText: contextText ?? this.contextText,
      questionMessageId: questionMessageId ?? this.questionMessageId,
      entryKind: entryKind ?? this.entryKind,
      status: status ?? this.status,
      endedAt: endedAt ?? this.endedAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (goalId.present) {
      map['goal_id'] = Variable<String>(goalId.value);
    }
    if (materialId.present) {
      map['material_id'] = Variable<String>(materialId.value);
    }
    if (pageNo.present) {
      map['page_no'] = Variable<int>(pageNo.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (contextText.present) {
      map['context_text'] = Variable<String>(contextText.value);
    }
    if (questionMessageId.present) {
      map['question_message_id'] = Variable<String>(questionMessageId.value);
    }
    if (entryKind.present) {
      map['entry_kind'] = Variable<String>(entryKind.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<String>(endedAt.value);
    }
    if (lastMessageAt.present) {
      map['last_message_at'] = Variable<String>(lastMessageAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('goalId: $goalId, ')
          ..write('materialId: $materialId, ')
          ..write('pageNo: $pageNo, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('contextText: $contextText, ')
          ..write('questionMessageId: $questionMessageId, ')
          ..write('entryKind: $entryKind, ')
          ..write('status: $status, ')
          ..write('endedAt: $endedAt, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversation (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    check: () => role.isIn(messageRoles),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imagePathsJsonMeta = const VerificationMeta(
    'imagePathsJson',
  );
  @override
  late final GeneratedColumn<String> imagePathsJson = GeneratedColumn<String>(
    'image_paths_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _structuredJsonMeta = const VerificationMeta(
    'structuredJson',
  );
  @override
  late final GeneratedColumn<String> structuredJson = GeneratedColumn<String>(
    'structured_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    conversationId,
    role,
    content,
    imagePathsJson,
    structuredJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('image_paths_json')) {
      context.handle(
        _imagePathsJsonMeta,
        imagePathsJson.isAcceptableOrUnknown(
          data['image_paths_json']!,
          _imagePathsJsonMeta,
        ),
      );
    }
    if (data.containsKey('structured_json')) {
      context.handle(
        _structuredJsonMeta,
        structuredJson.isAcceptableOrUnknown(
          data['structured_json']!,
          _structuredJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      imagePathsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}image_paths_json'],
      ),
      structuredJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}structured_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String conversationId;
  final String role;
  final String content;
  final String? imagePathsJson;
  final String? structuredJson;
  final String createdAt;
  const MessageRow({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePathsJson,
    this.structuredJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    if (!nullToAbsent || imagePathsJson != null) {
      map['image_paths_json'] = Variable<String>(imagePathsJson);
    }
    if (!nullToAbsent || structuredJson != null) {
      map['structured_json'] = Variable<String>(structuredJson);
    }
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      role: Value(role),
      content: Value(content),
      imagePathsJson: imagePathsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(imagePathsJson),
      structuredJson: structuredJson == null && nullToAbsent
          ? const Value.absent()
          : Value(structuredJson),
      createdAt: Value(createdAt),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      imagePathsJson: serializer.fromJson<String?>(json['imagePathsJson']),
      structuredJson: serializer.fromJson<String?>(json['structuredJson']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'imagePathsJson': serializer.toJson<String?>(imagePathsJson),
      'structuredJson': serializer.toJson<String?>(structuredJson),
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  MessageRow copyWith({
    String? id,
    String? conversationId,
    String? role,
    String? content,
    Value<String?> imagePathsJson = const Value.absent(),
    Value<String?> structuredJson = const Value.absent(),
    String? createdAt,
  }) => MessageRow(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    role: role ?? this.role,
    content: content ?? this.content,
    imagePathsJson: imagePathsJson.present
        ? imagePathsJson.value
        : this.imagePathsJson,
    structuredJson: structuredJson.present
        ? structuredJson.value
        : this.structuredJson,
    createdAt: createdAt ?? this.createdAt,
  );
  MessageRow copyWithCompanion(MessagesCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      imagePathsJson: data.imagePathsJson.present
          ? data.imagePathsJson.value
          : this.imagePathsJson,
      structuredJson: data.structuredJson.present
          ? data.structuredJson.value
          : this.structuredJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('imagePathsJson: $imagePathsJson, ')
          ..write('structuredJson: $structuredJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    role,
    content,
    imagePathsJson,
    structuredJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.role == this.role &&
          other.content == this.content &&
          other.imagePathsJson == this.imagePathsJson &&
          other.structuredJson == this.structuredJson &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> role;
  final Value<String> content;
  final Value<String?> imagePathsJson;
  final Value<String?> structuredJson;
  final Value<String> createdAt;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.imagePathsJson = const Value.absent(),
    this.structuredJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String role,
    required String content,
    this.imagePathsJson = const Value.absent(),
    this.structuredJson = const Value.absent(),
    required String createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       conversationId = Value(conversationId),
       role = Value(role),
       content = Value(content),
       createdAt = Value(createdAt);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<String>? imagePathsJson,
    Expression<String>? structuredJson,
    Expression<String>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (imagePathsJson != null) 'image_paths_json': imagePathsJson,
      if (structuredJson != null) 'structured_json': structuredJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? conversationId,
    Value<String>? role,
    Value<String>? content,
    Value<String?>? imagePathsJson,
    Value<String?>? structuredJson,
    Value<String>? createdAt,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      imagePathsJson: imagePathsJson ?? this.imagePathsJson,
      structuredJson: structuredJson ?? this.structuredJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (imagePathsJson.present) {
      map['image_paths_json'] = Variable<String>(imagePathsJson.value);
    }
    if (structuredJson.present) {
      map['structured_json'] = Variable<String>(structuredJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('imagePathsJson: $imagePathsJson, ')
          ..write('structuredJson: $structuredJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StudyPlansTable extends StudyPlans
    with TableInfo<$StudyPlansTable, StudyPlanRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StudyPlansTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _materialIdMeta = const VerificationMeta(
    'materialId',
  );
  @override
  late final GeneratedColumn<String> materialId = GeneratedColumn<String>(
    'material_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES material (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _goalIdMeta = const VerificationMeta('goalId');
  @override
  late final GeneratedColumn<String> goalId = GeneratedColumn<String>(
    'goal_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES learning_goal (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversation (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageFromMeta = const VerificationMeta(
    'pageFrom',
  );
  @override
  late final GeneratedColumn<int> pageFrom = GeneratedColumn<int>(
    'page_from',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageToMeta = const VerificationMeta('pageTo');
  @override
  late final GeneratedColumn<int> pageTo = GeneratedColumn<int>(
    'page_to',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currentPageMeta = const VerificationMeta(
    'currentPage',
  );
  @override
  late final GeneratedColumn<int> currentPage = GeneratedColumn<int>(
    'current_page',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(studyPlanStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    materialId,
    goalId,
    conversationId,
    title,
    pageFrom,
    pageTo,
    currentPage,
    status,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'study_plan';
  @override
  VerificationContext validateIntegrity(
    Insertable<StudyPlanRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('material_id')) {
      context.handle(
        _materialIdMeta,
        materialId.isAcceptableOrUnknown(data['material_id']!, _materialIdMeta),
      );
    }
    if (data.containsKey('goal_id')) {
      context.handle(
        _goalIdMeta,
        goalId.isAcceptableOrUnknown(data['goal_id']!, _goalIdMeta),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('page_from')) {
      context.handle(
        _pageFromMeta,
        pageFrom.isAcceptableOrUnknown(data['page_from']!, _pageFromMeta),
      );
    }
    if (data.containsKey('page_to')) {
      context.handle(
        _pageToMeta,
        pageTo.isAcceptableOrUnknown(data['page_to']!, _pageToMeta),
      );
    }
    if (data.containsKey('current_page')) {
      context.handle(
        _currentPageMeta,
        currentPage.isAcceptableOrUnknown(
          data['current_page']!,
          _currentPageMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StudyPlanRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StudyPlanRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      materialId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}material_id'],
      ),
      goalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}goal_id'],
      ),
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      pageFrom: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_from'],
      ),
      pageTo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_to'],
      ),
      currentPage: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}current_page'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $StudyPlansTable createAlias(String alias) {
    return $StudyPlansTable(attachedDatabase, alias);
  }
}

class StudyPlanRow extends DataClass implements Insertable<StudyPlanRow> {
  final String id;
  final String? materialId;
  final String? goalId;
  final String? conversationId;
  final String title;
  final int? pageFrom;
  final int? pageTo;
  final int? currentPage;
  final String status;
  final String createdAt;
  final String updatedAt;
  const StudyPlanRow({
    required this.id,
    this.materialId,
    this.goalId,
    this.conversationId,
    required this.title,
    this.pageFrom,
    this.pageTo,
    this.currentPage,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || materialId != null) {
      map['material_id'] = Variable<String>(materialId);
    }
    if (!nullToAbsent || goalId != null) {
      map['goal_id'] = Variable<String>(goalId);
    }
    if (!nullToAbsent || conversationId != null) {
      map['conversation_id'] = Variable<String>(conversationId);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || pageFrom != null) {
      map['page_from'] = Variable<int>(pageFrom);
    }
    if (!nullToAbsent || pageTo != null) {
      map['page_to'] = Variable<int>(pageTo);
    }
    if (!nullToAbsent || currentPage != null) {
      map['current_page'] = Variable<int>(currentPage);
    }
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  StudyPlansCompanion toCompanion(bool nullToAbsent) {
    return StudyPlansCompanion(
      id: Value(id),
      materialId: materialId == null && nullToAbsent
          ? const Value.absent()
          : Value(materialId),
      goalId: goalId == null && nullToAbsent
          ? const Value.absent()
          : Value(goalId),
      conversationId: conversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationId),
      title: Value(title),
      pageFrom: pageFrom == null && nullToAbsent
          ? const Value.absent()
          : Value(pageFrom),
      pageTo: pageTo == null && nullToAbsent
          ? const Value.absent()
          : Value(pageTo),
      currentPage: currentPage == null && nullToAbsent
          ? const Value.absent()
          : Value(currentPage),
      status: Value(status),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory StudyPlanRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StudyPlanRow(
      id: serializer.fromJson<String>(json['id']),
      materialId: serializer.fromJson<String?>(json['materialId']),
      goalId: serializer.fromJson<String?>(json['goalId']),
      conversationId: serializer.fromJson<String?>(json['conversationId']),
      title: serializer.fromJson<String>(json['title']),
      pageFrom: serializer.fromJson<int?>(json['pageFrom']),
      pageTo: serializer.fromJson<int?>(json['pageTo']),
      currentPage: serializer.fromJson<int?>(json['currentPage']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'materialId': serializer.toJson<String?>(materialId),
      'goalId': serializer.toJson<String?>(goalId),
      'conversationId': serializer.toJson<String?>(conversationId),
      'title': serializer.toJson<String>(title),
      'pageFrom': serializer.toJson<int?>(pageFrom),
      'pageTo': serializer.toJson<int?>(pageTo),
      'currentPage': serializer.toJson<int?>(currentPage),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  StudyPlanRow copyWith({
    String? id,
    Value<String?> materialId = const Value.absent(),
    Value<String?> goalId = const Value.absent(),
    Value<String?> conversationId = const Value.absent(),
    String? title,
    Value<int?> pageFrom = const Value.absent(),
    Value<int?> pageTo = const Value.absent(),
    Value<int?> currentPage = const Value.absent(),
    String? status,
    String? createdAt,
    String? updatedAt,
  }) => StudyPlanRow(
    id: id ?? this.id,
    materialId: materialId.present ? materialId.value : this.materialId,
    goalId: goalId.present ? goalId.value : this.goalId,
    conversationId: conversationId.present
        ? conversationId.value
        : this.conversationId,
    title: title ?? this.title,
    pageFrom: pageFrom.present ? pageFrom.value : this.pageFrom,
    pageTo: pageTo.present ? pageTo.value : this.pageTo,
    currentPage: currentPage.present ? currentPage.value : this.currentPage,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  StudyPlanRow copyWithCompanion(StudyPlansCompanion data) {
    return StudyPlanRow(
      id: data.id.present ? data.id.value : this.id,
      materialId: data.materialId.present
          ? data.materialId.value
          : this.materialId,
      goalId: data.goalId.present ? data.goalId.value : this.goalId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      title: data.title.present ? data.title.value : this.title,
      pageFrom: data.pageFrom.present ? data.pageFrom.value : this.pageFrom,
      pageTo: data.pageTo.present ? data.pageTo.value : this.pageTo,
      currentPage: data.currentPage.present
          ? data.currentPage.value
          : this.currentPage,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StudyPlanRow(')
          ..write('id: $id, ')
          ..write('materialId: $materialId, ')
          ..write('goalId: $goalId, ')
          ..write('conversationId: $conversationId, ')
          ..write('title: $title, ')
          ..write('pageFrom: $pageFrom, ')
          ..write('pageTo: $pageTo, ')
          ..write('currentPage: $currentPage, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    materialId,
    goalId,
    conversationId,
    title,
    pageFrom,
    pageTo,
    currentPage,
    status,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StudyPlanRow &&
          other.id == this.id &&
          other.materialId == this.materialId &&
          other.goalId == this.goalId &&
          other.conversationId == this.conversationId &&
          other.title == this.title &&
          other.pageFrom == this.pageFrom &&
          other.pageTo == this.pageTo &&
          other.currentPage == this.currentPage &&
          other.status == this.status &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class StudyPlansCompanion extends UpdateCompanion<StudyPlanRow> {
  final Value<String> id;
  final Value<String?> materialId;
  final Value<String?> goalId;
  final Value<String?> conversationId;
  final Value<String> title;
  final Value<int?> pageFrom;
  final Value<int?> pageTo;
  final Value<int?> currentPage;
  final Value<String> status;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const StudyPlansCompanion({
    this.id = const Value.absent(),
    this.materialId = const Value.absent(),
    this.goalId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.title = const Value.absent(),
    this.pageFrom = const Value.absent(),
    this.pageTo = const Value.absent(),
    this.currentPage = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StudyPlansCompanion.insert({
    required String id,
    this.materialId = const Value.absent(),
    this.goalId = const Value.absent(),
    this.conversationId = const Value.absent(),
    required String title,
    this.pageFrom = const Value.absent(),
    this.pageTo = const Value.absent(),
    this.currentPage = const Value.absent(),
    this.status = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<StudyPlanRow> custom({
    Expression<String>? id,
    Expression<String>? materialId,
    Expression<String>? goalId,
    Expression<String>? conversationId,
    Expression<String>? title,
    Expression<int>? pageFrom,
    Expression<int>? pageTo,
    Expression<int>? currentPage,
    Expression<String>? status,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (materialId != null) 'material_id': materialId,
      if (goalId != null) 'goal_id': goalId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (title != null) 'title': title,
      if (pageFrom != null) 'page_from': pageFrom,
      if (pageTo != null) 'page_to': pageTo,
      if (currentPage != null) 'current_page': currentPage,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StudyPlansCompanion copyWith({
    Value<String>? id,
    Value<String?>? materialId,
    Value<String?>? goalId,
    Value<String?>? conversationId,
    Value<String>? title,
    Value<int?>? pageFrom,
    Value<int?>? pageTo,
    Value<int?>? currentPage,
    Value<String>? status,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return StudyPlansCompanion(
      id: id ?? this.id,
      materialId: materialId ?? this.materialId,
      goalId: goalId ?? this.goalId,
      conversationId: conversationId ?? this.conversationId,
      title: title ?? this.title,
      pageFrom: pageFrom ?? this.pageFrom,
      pageTo: pageTo ?? this.pageTo,
      currentPage: currentPage ?? this.currentPage,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (materialId.present) {
      map['material_id'] = Variable<String>(materialId.value);
    }
    if (goalId.present) {
      map['goal_id'] = Variable<String>(goalId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (pageFrom.present) {
      map['page_from'] = Variable<int>(pageFrom.value);
    }
    if (pageTo.present) {
      map['page_to'] = Variable<int>(pageTo.value);
    }
    if (currentPage.present) {
      map['current_page'] = Variable<int>(currentPage.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StudyPlansCompanion(')
          ..write('id: $id, ')
          ..write('materialId: $materialId, ')
          ..write('goalId: $goalId, ')
          ..write('conversationId: $conversationId, ')
          ..write('title: $title, ')
          ..write('pageFrom: $pageFrom, ')
          ..write('pageTo: $pageTo, ')
          ..write('currentPage: $currentPage, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlanItemsTable extends PlanItems
    with TableInfo<$PlanItemsTable, PlanItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlanItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _goalIdMeta = const VerificationMeta('goalId');
  @override
  late final GeneratedColumn<String> goalId = GeneratedColumn<String>(
    'goal_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES learning_goal (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversation (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _studyPlanIdMeta = const VerificationMeta(
    'studyPlanId',
  );
  @override
  late final GeneratedColumn<String> studyPlanId = GeneratedColumn<String>(
    'study_plan_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES study_plan (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    true,
    check: () => seq.isNull() | ComparableExpr(seq).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageFromMeta = const VerificationMeta(
    'pageFrom',
  );
  @override
  late final GeneratedColumn<int> pageFrom = GeneratedColumn<int>(
    'page_from',
    aliasedName,
    true,
    check: () =>
        pageFrom.isNull() | ComparableExpr(pageFrom).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageToMeta = const VerificationMeta('pageTo');
  @override
  late final GeneratedColumn<int> pageTo = GeneratedColumn<int>(
    'page_to',
    aliasedName,
    true,
    check: () => pageTo.isNull() | ComparableExpr(pageTo).isBiggerThanValue(0),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueAtMeta = const VerificationMeta('dueAt');
  @override
  late final GeneratedColumn<String> dueAt = GeneratedColumn<String>(
    'due_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _estMinutesMeta = const VerificationMeta(
    'estMinutes',
  );
  @override
  late final GeneratedColumn<int> estMinutes = GeneratedColumn<int>(
    'est_minutes',
    aliasedName,
    true,
    check: () =>
        estMinutes.isNull() |
        ComparableExpr(estMinutes).isBetweenValues(5, 240),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
    'priority',
    aliasedName,
    false,
    check: () => ComparableExpr(priority).isBetweenValues(0, 2),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(planItemStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('todo'),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    check: () => source.isIn(sourceValues),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('user'),
  );
  static const VerificationMeta _originJsonMeta = const VerificationMeta(
    'originJson',
  );
  @override
  late final GeneratedColumn<String> originJson = GeneratedColumn<String>(
    'origin_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<String> completedAt = GeneratedColumn<String>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    goalId,
    conversationId,
    studyPlanId,
    seq,
    title,
    note,
    pageFrom,
    pageTo,
    dueAt,
    estMinutes,
    priority,
    status,
    source,
    originJson,
    completedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plan_item';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlanItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('goal_id')) {
      context.handle(
        _goalIdMeta,
        goalId.isAcceptableOrUnknown(data['goal_id']!, _goalIdMeta),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    }
    if (data.containsKey('study_plan_id')) {
      context.handle(
        _studyPlanIdMeta,
        studyPlanId.isAcceptableOrUnknown(
          data['study_plan_id']!,
          _studyPlanIdMeta,
        ),
      );
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('page_from')) {
      context.handle(
        _pageFromMeta,
        pageFrom.isAcceptableOrUnknown(data['page_from']!, _pageFromMeta),
      );
    }
    if (data.containsKey('page_to')) {
      context.handle(
        _pageToMeta,
        pageTo.isAcceptableOrUnknown(data['page_to']!, _pageToMeta),
      );
    }
    if (data.containsKey('due_at')) {
      context.handle(
        _dueAtMeta,
        dueAt.isAcceptableOrUnknown(data['due_at']!, _dueAtMeta),
      );
    }
    if (data.containsKey('est_minutes')) {
      context.handle(
        _estMinutesMeta,
        estMinutes.isAcceptableOrUnknown(data['est_minutes']!, _estMinutesMeta),
      );
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('origin_json')) {
      context.handle(
        _originJsonMeta,
        originJson.isAcceptableOrUnknown(data['origin_json']!, _originJsonMeta),
      );
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlanItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlanItemRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      goalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}goal_id'],
      ),
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      ),
      studyPlanId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}study_plan_id'],
      ),
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      pageFrom: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_from'],
      ),
      pageTo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_to'],
      ),
      dueAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}due_at'],
      ),
      estMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}est_minutes'],
      ),
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}priority'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      originJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin_json'],
      ),
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}completed_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $PlanItemsTable createAlias(String alias) {
    return $PlanItemsTable(attachedDatabase, alias);
  }
}

class PlanItemRow extends DataClass implements Insertable<PlanItemRow> {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  const PlanItemRow({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || goalId != null) {
      map['goal_id'] = Variable<String>(goalId);
    }
    if (!nullToAbsent || conversationId != null) {
      map['conversation_id'] = Variable<String>(conversationId);
    }
    if (!nullToAbsent || studyPlanId != null) {
      map['study_plan_id'] = Variable<String>(studyPlanId);
    }
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    if (!nullToAbsent || pageFrom != null) {
      map['page_from'] = Variable<int>(pageFrom);
    }
    if (!nullToAbsent || pageTo != null) {
      map['page_to'] = Variable<int>(pageTo);
    }
    if (!nullToAbsent || dueAt != null) {
      map['due_at'] = Variable<String>(dueAt);
    }
    if (!nullToAbsent || estMinutes != null) {
      map['est_minutes'] = Variable<int>(estMinutes);
    }
    map['priority'] = Variable<int>(priority);
    map['status'] = Variable<String>(status);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || originJson != null) {
      map['origin_json'] = Variable<String>(originJson);
    }
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<String>(completedAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  PlanItemsCompanion toCompanion(bool nullToAbsent) {
    return PlanItemsCompanion(
      id: Value(id),
      goalId: goalId == null && nullToAbsent
          ? const Value.absent()
          : Value(goalId),
      conversationId: conversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationId),
      studyPlanId: studyPlanId == null && nullToAbsent
          ? const Value.absent()
          : Value(studyPlanId),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      title: Value(title),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      pageFrom: pageFrom == null && nullToAbsent
          ? const Value.absent()
          : Value(pageFrom),
      pageTo: pageTo == null && nullToAbsent
          ? const Value.absent()
          : Value(pageTo),
      dueAt: dueAt == null && nullToAbsent
          ? const Value.absent()
          : Value(dueAt),
      estMinutes: estMinutes == null && nullToAbsent
          ? const Value.absent()
          : Value(estMinutes),
      priority: Value(priority),
      status: Value(status),
      source: Value(source),
      originJson: originJson == null && nullToAbsent
          ? const Value.absent()
          : Value(originJson),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory PlanItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlanItemRow(
      id: serializer.fromJson<String>(json['id']),
      goalId: serializer.fromJson<String?>(json['goalId']),
      conversationId: serializer.fromJson<String?>(json['conversationId']),
      studyPlanId: serializer.fromJson<String?>(json['studyPlanId']),
      seq: serializer.fromJson<int?>(json['seq']),
      title: serializer.fromJson<String>(json['title']),
      note: serializer.fromJson<String?>(json['note']),
      pageFrom: serializer.fromJson<int?>(json['pageFrom']),
      pageTo: serializer.fromJson<int?>(json['pageTo']),
      dueAt: serializer.fromJson<String?>(json['dueAt']),
      estMinutes: serializer.fromJson<int?>(json['estMinutes']),
      priority: serializer.fromJson<int>(json['priority']),
      status: serializer.fromJson<String>(json['status']),
      source: serializer.fromJson<String>(json['source']),
      originJson: serializer.fromJson<String?>(json['originJson']),
      completedAt: serializer.fromJson<String?>(json['completedAt']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'goalId': serializer.toJson<String?>(goalId),
      'conversationId': serializer.toJson<String?>(conversationId),
      'studyPlanId': serializer.toJson<String?>(studyPlanId),
      'seq': serializer.toJson<int?>(seq),
      'title': serializer.toJson<String>(title),
      'note': serializer.toJson<String?>(note),
      'pageFrom': serializer.toJson<int?>(pageFrom),
      'pageTo': serializer.toJson<int?>(pageTo),
      'dueAt': serializer.toJson<String?>(dueAt),
      'estMinutes': serializer.toJson<int?>(estMinutes),
      'priority': serializer.toJson<int>(priority),
      'status': serializer.toJson<String>(status),
      'source': serializer.toJson<String>(source),
      'originJson': serializer.toJson<String?>(originJson),
      'completedAt': serializer.toJson<String?>(completedAt),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  PlanItemRow copyWith({
    String? id,
    Value<String?> goalId = const Value.absent(),
    Value<String?> conversationId = const Value.absent(),
    Value<String?> studyPlanId = const Value.absent(),
    Value<int?> seq = const Value.absent(),
    String? title,
    Value<String?> note = const Value.absent(),
    Value<int?> pageFrom = const Value.absent(),
    Value<int?> pageTo = const Value.absent(),
    Value<String?> dueAt = const Value.absent(),
    Value<int?> estMinutes = const Value.absent(),
    int? priority,
    String? status,
    String? source,
    Value<String?> originJson = const Value.absent(),
    Value<String?> completedAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => PlanItemRow(
    id: id ?? this.id,
    goalId: goalId.present ? goalId.value : this.goalId,
    conversationId: conversationId.present
        ? conversationId.value
        : this.conversationId,
    studyPlanId: studyPlanId.present ? studyPlanId.value : this.studyPlanId,
    seq: seq.present ? seq.value : this.seq,
    title: title ?? this.title,
    note: note.present ? note.value : this.note,
    pageFrom: pageFrom.present ? pageFrom.value : this.pageFrom,
    pageTo: pageTo.present ? pageTo.value : this.pageTo,
    dueAt: dueAt.present ? dueAt.value : this.dueAt,
    estMinutes: estMinutes.present ? estMinutes.value : this.estMinutes,
    priority: priority ?? this.priority,
    status: status ?? this.status,
    source: source ?? this.source,
    originJson: originJson.present ? originJson.value : this.originJson,
    completedAt: completedAt.present ? completedAt.value : this.completedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  PlanItemRow copyWithCompanion(PlanItemsCompanion data) {
    return PlanItemRow(
      id: data.id.present ? data.id.value : this.id,
      goalId: data.goalId.present ? data.goalId.value : this.goalId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      studyPlanId: data.studyPlanId.present
          ? data.studyPlanId.value
          : this.studyPlanId,
      seq: data.seq.present ? data.seq.value : this.seq,
      title: data.title.present ? data.title.value : this.title,
      note: data.note.present ? data.note.value : this.note,
      pageFrom: data.pageFrom.present ? data.pageFrom.value : this.pageFrom,
      pageTo: data.pageTo.present ? data.pageTo.value : this.pageTo,
      dueAt: data.dueAt.present ? data.dueAt.value : this.dueAt,
      estMinutes: data.estMinutes.present
          ? data.estMinutes.value
          : this.estMinutes,
      priority: data.priority.present ? data.priority.value : this.priority,
      status: data.status.present ? data.status.value : this.status,
      source: data.source.present ? data.source.value : this.source,
      originJson: data.originJson.present
          ? data.originJson.value
          : this.originJson,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlanItemRow(')
          ..write('id: $id, ')
          ..write('goalId: $goalId, ')
          ..write('conversationId: $conversationId, ')
          ..write('studyPlanId: $studyPlanId, ')
          ..write('seq: $seq, ')
          ..write('title: $title, ')
          ..write('note: $note, ')
          ..write('pageFrom: $pageFrom, ')
          ..write('pageTo: $pageTo, ')
          ..write('dueAt: $dueAt, ')
          ..write('estMinutes: $estMinutes, ')
          ..write('priority: $priority, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('originJson: $originJson, ')
          ..write('completedAt: $completedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    goalId,
    conversationId,
    studyPlanId,
    seq,
    title,
    note,
    pageFrom,
    pageTo,
    dueAt,
    estMinutes,
    priority,
    status,
    source,
    originJson,
    completedAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlanItemRow &&
          other.id == this.id &&
          other.goalId == this.goalId &&
          other.conversationId == this.conversationId &&
          other.studyPlanId == this.studyPlanId &&
          other.seq == this.seq &&
          other.title == this.title &&
          other.note == this.note &&
          other.pageFrom == this.pageFrom &&
          other.pageTo == this.pageTo &&
          other.dueAt == this.dueAt &&
          other.estMinutes == this.estMinutes &&
          other.priority == this.priority &&
          other.status == this.status &&
          other.source == this.source &&
          other.originJson == this.originJson &&
          other.completedAt == this.completedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class PlanItemsCompanion extends UpdateCompanion<PlanItemRow> {
  final Value<String> id;
  final Value<String?> goalId;
  final Value<String?> conversationId;
  final Value<String?> studyPlanId;
  final Value<int?> seq;
  final Value<String> title;
  final Value<String?> note;
  final Value<int?> pageFrom;
  final Value<int?> pageTo;
  final Value<String?> dueAt;
  final Value<int?> estMinutes;
  final Value<int> priority;
  final Value<String> status;
  final Value<String> source;
  final Value<String?> originJson;
  final Value<String?> completedAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const PlanItemsCompanion({
    this.id = const Value.absent(),
    this.goalId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.studyPlanId = const Value.absent(),
    this.seq = const Value.absent(),
    this.title = const Value.absent(),
    this.note = const Value.absent(),
    this.pageFrom = const Value.absent(),
    this.pageTo = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.estMinutes = const Value.absent(),
    this.priority = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.originJson = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlanItemsCompanion.insert({
    required String id,
    this.goalId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.studyPlanId = const Value.absent(),
    this.seq = const Value.absent(),
    required String title,
    this.note = const Value.absent(),
    this.pageFrom = const Value.absent(),
    this.pageTo = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.estMinutes = const Value.absent(),
    this.priority = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.originJson = const Value.absent(),
    this.completedAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<PlanItemRow> custom({
    Expression<String>? id,
    Expression<String>? goalId,
    Expression<String>? conversationId,
    Expression<String>? studyPlanId,
    Expression<int>? seq,
    Expression<String>? title,
    Expression<String>? note,
    Expression<int>? pageFrom,
    Expression<int>? pageTo,
    Expression<String>? dueAt,
    Expression<int>? estMinutes,
    Expression<int>? priority,
    Expression<String>? status,
    Expression<String>? source,
    Expression<String>? originJson,
    Expression<String>? completedAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (goalId != null) 'goal_id': goalId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (studyPlanId != null) 'study_plan_id': studyPlanId,
      if (seq != null) 'seq': seq,
      if (title != null) 'title': title,
      if (note != null) 'note': note,
      if (pageFrom != null) 'page_from': pageFrom,
      if (pageTo != null) 'page_to': pageTo,
      if (dueAt != null) 'due_at': dueAt,
      if (estMinutes != null) 'est_minutes': estMinutes,
      if (priority != null) 'priority': priority,
      if (status != null) 'status': status,
      if (source != null) 'source': source,
      if (originJson != null) 'origin_json': originJson,
      if (completedAt != null) 'completed_at': completedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlanItemsCompanion copyWith({
    Value<String>? id,
    Value<String?>? goalId,
    Value<String?>? conversationId,
    Value<String?>? studyPlanId,
    Value<int?>? seq,
    Value<String>? title,
    Value<String?>? note,
    Value<int?>? pageFrom,
    Value<int?>? pageTo,
    Value<String?>? dueAt,
    Value<int?>? estMinutes,
    Value<int>? priority,
    Value<String>? status,
    Value<String>? source,
    Value<String?>? originJson,
    Value<String?>? completedAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return PlanItemsCompanion(
      id: id ?? this.id,
      goalId: goalId ?? this.goalId,
      conversationId: conversationId ?? this.conversationId,
      studyPlanId: studyPlanId ?? this.studyPlanId,
      seq: seq ?? this.seq,
      title: title ?? this.title,
      note: note ?? this.note,
      pageFrom: pageFrom ?? this.pageFrom,
      pageTo: pageTo ?? this.pageTo,
      dueAt: dueAt ?? this.dueAt,
      estMinutes: estMinutes ?? this.estMinutes,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      source: source ?? this.source,
      originJson: originJson ?? this.originJson,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (goalId.present) {
      map['goal_id'] = Variable<String>(goalId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (studyPlanId.present) {
      map['study_plan_id'] = Variable<String>(studyPlanId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (pageFrom.present) {
      map['page_from'] = Variable<int>(pageFrom.value);
    }
    if (pageTo.present) {
      map['page_to'] = Variable<int>(pageTo.value);
    }
    if (dueAt.present) {
      map['due_at'] = Variable<String>(dueAt.value);
    }
    if (estMinutes.present) {
      map['est_minutes'] = Variable<int>(estMinutes.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (originJson.present) {
      map['origin_json'] = Variable<String>(originJson.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<String>(completedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlanItemsCompanion(')
          ..write('id: $id, ')
          ..write('goalId: $goalId, ')
          ..write('conversationId: $conversationId, ')
          ..write('studyPlanId: $studyPlanId, ')
          ..write('seq: $seq, ')
          ..write('title: $title, ')
          ..write('note: $note, ')
          ..write('pageFrom: $pageFrom, ')
          ..write('pageTo: $pageTo, ')
          ..write('dueAt: $dueAt, ')
          ..write('estMinutes: $estMinutes, ')
          ..write('priority: $priority, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('originJson: $originJson, ')
          ..write('completedAt: $completedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScheduleBlocksTable extends ScheduleBlocks
    with TableInfo<$ScheduleBlocksTable, ScheduleBlockRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScheduleBlocksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _planItemIdMeta = const VerificationMeta(
    'planItemId',
  );
  @override
  late final GeneratedColumn<String> planItemId = GeneratedColumn<String>(
    'plan_item_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_item (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _startAtMeta = const VerificationMeta(
    'startAt',
  );
  @override
  late final GeneratedColumn<String> startAt = GeneratedColumn<String>(
    'start_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endAtMeta = const VerificationMeta('endAt');
  @override
  late final GeneratedColumn<String> endAt = GeneratedColumn<String>(
    'end_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    check: () => source.isIn(sourceValues),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('user'),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(scheduleBlockStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('planned'),
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    planItemId,
    startAt,
    endAt,
    source,
    status,
    locked,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'schedule_block';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScheduleBlockRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('plan_item_id')) {
      context.handle(
        _planItemIdMeta,
        planItemId.isAcceptableOrUnknown(
          data['plan_item_id']!,
          _planItemIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_planItemIdMeta);
    }
    if (data.containsKey('start_at')) {
      context.handle(
        _startAtMeta,
        startAt.isAcceptableOrUnknown(data['start_at']!, _startAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startAtMeta);
    }
    if (data.containsKey('end_at')) {
      context.handle(
        _endAtMeta,
        endAt.isAcceptableOrUnknown(data['end_at']!, _endAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endAtMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ScheduleBlockRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScheduleBlockRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      planItemId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}plan_item_id'],
      )!,
      startAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start_at'],
      )!,
      endAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_at'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ScheduleBlocksTable createAlias(String alias) {
    return $ScheduleBlocksTable(attachedDatabase, alias);
  }
}

class ScheduleBlockRow extends DataClass
    implements Insertable<ScheduleBlockRow> {
  final String id;
  final String planItemId;
  final String startAt;
  final String endAt;
  final String source;
  final String status;
  final bool locked;
  final String createdAt;
  final String updatedAt;
  const ScheduleBlockRow({
    required this.id,
    required this.planItemId,
    required this.startAt,
    required this.endAt,
    required this.source,
    required this.status,
    required this.locked,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['plan_item_id'] = Variable<String>(planItemId);
    map['start_at'] = Variable<String>(startAt);
    map['end_at'] = Variable<String>(endAt);
    map['source'] = Variable<String>(source);
    map['status'] = Variable<String>(status);
    map['locked'] = Variable<bool>(locked);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  ScheduleBlocksCompanion toCompanion(bool nullToAbsent) {
    return ScheduleBlocksCompanion(
      id: Value(id),
      planItemId: Value(planItemId),
      startAt: Value(startAt),
      endAt: Value(endAt),
      source: Value(source),
      status: Value(status),
      locked: Value(locked),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ScheduleBlockRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScheduleBlockRow(
      id: serializer.fromJson<String>(json['id']),
      planItemId: serializer.fromJson<String>(json['planItemId']),
      startAt: serializer.fromJson<String>(json['startAt']),
      endAt: serializer.fromJson<String>(json['endAt']),
      source: serializer.fromJson<String>(json['source']),
      status: serializer.fromJson<String>(json['status']),
      locked: serializer.fromJson<bool>(json['locked']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'planItemId': serializer.toJson<String>(planItemId),
      'startAt': serializer.toJson<String>(startAt),
      'endAt': serializer.toJson<String>(endAt),
      'source': serializer.toJson<String>(source),
      'status': serializer.toJson<String>(status),
      'locked': serializer.toJson<bool>(locked),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  ScheduleBlockRow copyWith({
    String? id,
    String? planItemId,
    String? startAt,
    String? endAt,
    String? source,
    String? status,
    bool? locked,
    String? createdAt,
    String? updatedAt,
  }) => ScheduleBlockRow(
    id: id ?? this.id,
    planItemId: planItemId ?? this.planItemId,
    startAt: startAt ?? this.startAt,
    endAt: endAt ?? this.endAt,
    source: source ?? this.source,
    status: status ?? this.status,
    locked: locked ?? this.locked,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ScheduleBlockRow copyWithCompanion(ScheduleBlocksCompanion data) {
    return ScheduleBlockRow(
      id: data.id.present ? data.id.value : this.id,
      planItemId: data.planItemId.present
          ? data.planItemId.value
          : this.planItemId,
      startAt: data.startAt.present ? data.startAt.value : this.startAt,
      endAt: data.endAt.present ? data.endAt.value : this.endAt,
      source: data.source.present ? data.source.value : this.source,
      status: data.status.present ? data.status.value : this.status,
      locked: data.locked.present ? data.locked.value : this.locked,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleBlockRow(')
          ..write('id: $id, ')
          ..write('planItemId: $planItemId, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('source: $source, ')
          ..write('status: $status, ')
          ..write('locked: $locked, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    planItemId,
    startAt,
    endAt,
    source,
    status,
    locked,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduleBlockRow &&
          other.id == this.id &&
          other.planItemId == this.planItemId &&
          other.startAt == this.startAt &&
          other.endAt == this.endAt &&
          other.source == this.source &&
          other.status == this.status &&
          other.locked == this.locked &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ScheduleBlocksCompanion extends UpdateCompanion<ScheduleBlockRow> {
  final Value<String> id;
  final Value<String> planItemId;
  final Value<String> startAt;
  final Value<String> endAt;
  final Value<String> source;
  final Value<String> status;
  final Value<bool> locked;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const ScheduleBlocksCompanion({
    this.id = const Value.absent(),
    this.planItemId = const Value.absent(),
    this.startAt = const Value.absent(),
    this.endAt = const Value.absent(),
    this.source = const Value.absent(),
    this.status = const Value.absent(),
    this.locked = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScheduleBlocksCompanion.insert({
    required String id,
    required String planItemId,
    required String startAt,
    required String endAt,
    this.source = const Value.absent(),
    this.status = const Value.absent(),
    this.locked = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       planItemId = Value(planItemId),
       startAt = Value(startAt),
       endAt = Value(endAt),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ScheduleBlockRow> custom({
    Expression<String>? id,
    Expression<String>? planItemId,
    Expression<String>? startAt,
    Expression<String>? endAt,
    Expression<String>? source,
    Expression<String>? status,
    Expression<bool>? locked,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (planItemId != null) 'plan_item_id': planItemId,
      if (startAt != null) 'start_at': startAt,
      if (endAt != null) 'end_at': endAt,
      if (source != null) 'source': source,
      if (status != null) 'status': status,
      if (locked != null) 'locked': locked,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScheduleBlocksCompanion copyWith({
    Value<String>? id,
    Value<String>? planItemId,
    Value<String>? startAt,
    Value<String>? endAt,
    Value<String>? source,
    Value<String>? status,
    Value<bool>? locked,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return ScheduleBlocksCompanion(
      id: id ?? this.id,
      planItemId: planItemId ?? this.planItemId,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      source: source ?? this.source,
      status: status ?? this.status,
      locked: locked ?? this.locked,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (planItemId.present) {
      map['plan_item_id'] = Variable<String>(planItemId.value);
    }
    if (startAt.present) {
      map['start_at'] = Variable<String>(startAt.value);
    }
    if (endAt.present) {
      map['end_at'] = Variable<String>(endAt.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleBlocksCompanion(')
          ..write('id: $id, ')
          ..write('planItemId: $planItemId, ')
          ..write('startAt: $startAt, ')
          ..write('endAt: $endAt, ')
          ..write('source: $source, ')
          ..write('status: $status, ')
          ..write('locked: $locked, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StudySessionsTable extends StudySessions
    with TableInfo<$StudySessionsTable, StudySessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StudySessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _goalIdMeta = const VerificationMeta('goalId');
  @override
  late final GeneratedColumn<String> goalId = GeneratedColumn<String>(
    'goal_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES learning_goal (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _planItemIdMeta = const VerificationMeta(
    'planItemId',
  );
  @override
  late final GeneratedColumn<String> planItemId = GeneratedColumn<String>(
    'plan_item_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_item (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversation (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _outcomeMeta = const VerificationMeta(
    'outcome',
  );
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
    'outcome',
    aliasedName,
    true,
    check: () => outcome.isIn(sessionOutcomes),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<String> startedAt = GeneratedColumn<String>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<String> endedAt = GeneratedColumn<String>(
    'ended_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    goalId,
    planItemId,
    conversationId,
    summary,
    outcome,
    startedAt,
    endedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'study_session';
  @override
  VerificationContext validateIntegrity(
    Insertable<StudySessionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('goal_id')) {
      context.handle(
        _goalIdMeta,
        goalId.isAcceptableOrUnknown(data['goal_id']!, _goalIdMeta),
      );
    }
    if (data.containsKey('plan_item_id')) {
      context.handle(
        _planItemIdMeta,
        planItemId.isAcceptableOrUnknown(
          data['plan_item_id']!,
          _planItemIdMeta,
        ),
      );
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('outcome')) {
      context.handle(
        _outcomeMeta,
        outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta),
      );
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StudySessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StudySessionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      goalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}goal_id'],
      ),
      planItemId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}plan_item_id'],
      ),
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      outcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outcome'],
      ),
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}started_at'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ended_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $StudySessionsTable createAlias(String alias) {
    return $StudySessionsTable(attachedDatabase, alias);
  }
}

class StudySessionRow extends DataClass implements Insertable<StudySessionRow> {
  final String id;
  final String? goalId;
  final String? planItemId;
  final String? conversationId;
  final String? summary;
  final String? outcome;
  final String startedAt;
  final String? endedAt;
  final String createdAt;
  final String updatedAt;
  const StudySessionRow({
    required this.id,
    this.goalId,
    this.planItemId,
    this.conversationId,
    this.summary,
    this.outcome,
    required this.startedAt,
    this.endedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || goalId != null) {
      map['goal_id'] = Variable<String>(goalId);
    }
    if (!nullToAbsent || planItemId != null) {
      map['plan_item_id'] = Variable<String>(planItemId);
    }
    if (!nullToAbsent || conversationId != null) {
      map['conversation_id'] = Variable<String>(conversationId);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || outcome != null) {
      map['outcome'] = Variable<String>(outcome);
    }
    map['started_at'] = Variable<String>(startedAt);
    if (!nullToAbsent || endedAt != null) {
      map['ended_at'] = Variable<String>(endedAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  StudySessionsCompanion toCompanion(bool nullToAbsent) {
    return StudySessionsCompanion(
      id: Value(id),
      goalId: goalId == null && nullToAbsent
          ? const Value.absent()
          : Value(goalId),
      planItemId: planItemId == null && nullToAbsent
          ? const Value.absent()
          : Value(planItemId),
      conversationId: conversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationId),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      outcome: outcome == null && nullToAbsent
          ? const Value.absent()
          : Value(outcome),
      startedAt: Value(startedAt),
      endedAt: endedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory StudySessionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StudySessionRow(
      id: serializer.fromJson<String>(json['id']),
      goalId: serializer.fromJson<String?>(json['goalId']),
      planItemId: serializer.fromJson<String?>(json['planItemId']),
      conversationId: serializer.fromJson<String?>(json['conversationId']),
      summary: serializer.fromJson<String?>(json['summary']),
      outcome: serializer.fromJson<String?>(json['outcome']),
      startedAt: serializer.fromJson<String>(json['startedAt']),
      endedAt: serializer.fromJson<String?>(json['endedAt']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'goalId': serializer.toJson<String?>(goalId),
      'planItemId': serializer.toJson<String?>(planItemId),
      'conversationId': serializer.toJson<String?>(conversationId),
      'summary': serializer.toJson<String?>(summary),
      'outcome': serializer.toJson<String?>(outcome),
      'startedAt': serializer.toJson<String>(startedAt),
      'endedAt': serializer.toJson<String?>(endedAt),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  StudySessionRow copyWith({
    String? id,
    Value<String?> goalId = const Value.absent(),
    Value<String?> planItemId = const Value.absent(),
    Value<String?> conversationId = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    Value<String?> outcome = const Value.absent(),
    String? startedAt,
    Value<String?> endedAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => StudySessionRow(
    id: id ?? this.id,
    goalId: goalId.present ? goalId.value : this.goalId,
    planItemId: planItemId.present ? planItemId.value : this.planItemId,
    conversationId: conversationId.present
        ? conversationId.value
        : this.conversationId,
    summary: summary.present ? summary.value : this.summary,
    outcome: outcome.present ? outcome.value : this.outcome,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt.present ? endedAt.value : this.endedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  StudySessionRow copyWithCompanion(StudySessionsCompanion data) {
    return StudySessionRow(
      id: data.id.present ? data.id.value : this.id,
      goalId: data.goalId.present ? data.goalId.value : this.goalId,
      planItemId: data.planItemId.present
          ? data.planItemId.value
          : this.planItemId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      summary: data.summary.present ? data.summary.value : this.summary,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StudySessionRow(')
          ..write('id: $id, ')
          ..write('goalId: $goalId, ')
          ..write('planItemId: $planItemId, ')
          ..write('conversationId: $conversationId, ')
          ..write('summary: $summary, ')
          ..write('outcome: $outcome, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    goalId,
    planItemId,
    conversationId,
    summary,
    outcome,
    startedAt,
    endedAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StudySessionRow &&
          other.id == this.id &&
          other.goalId == this.goalId &&
          other.planItemId == this.planItemId &&
          other.conversationId == this.conversationId &&
          other.summary == this.summary &&
          other.outcome == this.outcome &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class StudySessionsCompanion extends UpdateCompanion<StudySessionRow> {
  final Value<String> id;
  final Value<String?> goalId;
  final Value<String?> planItemId;
  final Value<String?> conversationId;
  final Value<String?> summary;
  final Value<String?> outcome;
  final Value<String> startedAt;
  final Value<String?> endedAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const StudySessionsCompanion({
    this.id = const Value.absent(),
    this.goalId = const Value.absent(),
    this.planItemId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.summary = const Value.absent(),
    this.outcome = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StudySessionsCompanion.insert({
    required String id,
    this.goalId = const Value.absent(),
    this.planItemId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.summary = const Value.absent(),
    this.outcome = const Value.absent(),
    required String startedAt,
    this.endedAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       startedAt = Value(startedAt),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<StudySessionRow> custom({
    Expression<String>? id,
    Expression<String>? goalId,
    Expression<String>? planItemId,
    Expression<String>? conversationId,
    Expression<String>? summary,
    Expression<String>? outcome,
    Expression<String>? startedAt,
    Expression<String>? endedAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (goalId != null) 'goal_id': goalId,
      if (planItemId != null) 'plan_item_id': planItemId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (summary != null) 'summary': summary,
      if (outcome != null) 'outcome': outcome,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StudySessionsCompanion copyWith({
    Value<String>? id,
    Value<String?>? goalId,
    Value<String?>? planItemId,
    Value<String?>? conversationId,
    Value<String?>? summary,
    Value<String?>? outcome,
    Value<String>? startedAt,
    Value<String?>? endedAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return StudySessionsCompanion(
      id: id ?? this.id,
      goalId: goalId ?? this.goalId,
      planItemId: planItemId ?? this.planItemId,
      conversationId: conversationId ?? this.conversationId,
      summary: summary ?? this.summary,
      outcome: outcome ?? this.outcome,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (goalId.present) {
      map['goal_id'] = Variable<String>(goalId.value);
    }
    if (planItemId.present) {
      map['plan_item_id'] = Variable<String>(planItemId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<String>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<String>(endedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StudySessionsCompanion(')
          ..write('id: $id, ')
          ..write('goalId: $goalId, ')
          ..write('planItemId: $planItemId, ')
          ..write('conversationId: $conversationId, ')
          ..write('summary: $summary, ')
          ..write('outcome: $outcome, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttemptsTable extends Attempts
    with TableInfo<$AttemptsTable, AttemptRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttemptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversation (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES study_session (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _redoOfAttemptIdMeta = const VerificationMeta(
    'redoOfAttemptId',
  );
  @override
  late final GeneratedColumn<String> redoOfAttemptId = GeneratedColumn<String>(
    'redo_of_attempt_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES attempt (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _userAnswerMeta = const VerificationMeta(
    'userAnswer',
  );
  @override
  late final GeneratedColumn<String> userAnswer = GeneratedColumn<String>(
    'user_answer',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _solutionMeta = const VerificationMeta(
    'solution',
  );
  @override
  late final GeneratedColumn<String> solution = GeneratedColumn<String>(
    'solution',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isCorrectMeta = const VerificationMeta(
    'isCorrect',
  );
  @override
  late final GeneratedColumn<bool> isCorrect = GeneratedColumn<bool>(
    'is_correct',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_correct" IN (0, 1))',
    ),
  );
  static const VerificationMeta _independentMeta = const VerificationMeta(
    'independent',
  );
  @override
  late final GeneratedColumn<bool> independent = GeneratedColumn<bool>(
    'independent',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("independent" IN (0, 1))',
    ),
  );
  static const VerificationMeta _delayedMeta = const VerificationMeta(
    'delayed',
  );
  @override
  late final GeneratedColumn<bool> delayed = GeneratedColumn<bool>(
    'delayed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("delayed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _helpJsonMeta = const VerificationMeta(
    'helpJson',
  );
  @override
  late final GeneratedColumn<String> helpJson = GeneratedColumn<String>(
    'help_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _feedbackMeta = const VerificationMeta(
    'feedback',
  );
  @override
  late final GeneratedColumn<String> feedback = GeneratedColumn<String>(
    'feedback',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _submittedAtMeta = const VerificationMeta(
    'submittedAt',
  );
  @override
  late final GeneratedColumn<String> submittedAt = GeneratedColumn<String>(
    'submitted_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    conversationId,
    sessionId,
    redoOfAttemptId,
    userAnswer,
    solution,
    isCorrect,
    independent,
    delayed,
    helpJson,
    feedback,
    submittedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attempt';
  @override
  VerificationContext validateIntegrity(
    Insertable<AttemptRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    }
    if (data.containsKey('redo_of_attempt_id')) {
      context.handle(
        _redoOfAttemptIdMeta,
        redoOfAttemptId.isAcceptableOrUnknown(
          data['redo_of_attempt_id']!,
          _redoOfAttemptIdMeta,
        ),
      );
    }
    if (data.containsKey('user_answer')) {
      context.handle(
        _userAnswerMeta,
        userAnswer.isAcceptableOrUnknown(data['user_answer']!, _userAnswerMeta),
      );
    }
    if (data.containsKey('solution')) {
      context.handle(
        _solutionMeta,
        solution.isAcceptableOrUnknown(data['solution']!, _solutionMeta),
      );
    }
    if (data.containsKey('is_correct')) {
      context.handle(
        _isCorrectMeta,
        isCorrect.isAcceptableOrUnknown(data['is_correct']!, _isCorrectMeta),
      );
    }
    if (data.containsKey('independent')) {
      context.handle(
        _independentMeta,
        independent.isAcceptableOrUnknown(
          data['independent']!,
          _independentMeta,
        ),
      );
    }
    if (data.containsKey('delayed')) {
      context.handle(
        _delayedMeta,
        delayed.isAcceptableOrUnknown(data['delayed']!, _delayedMeta),
      );
    }
    if (data.containsKey('help_json')) {
      context.handle(
        _helpJsonMeta,
        helpJson.isAcceptableOrUnknown(data['help_json']!, _helpJsonMeta),
      );
    }
    if (data.containsKey('feedback')) {
      context.handle(
        _feedbackMeta,
        feedback.isAcceptableOrUnknown(data['feedback']!, _feedbackMeta),
      );
    }
    if (data.containsKey('submitted_at')) {
      context.handle(
        _submittedAtMeta,
        submittedAt.isAcceptableOrUnknown(
          data['submitted_at']!,
          _submittedAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AttemptRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AttemptRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      ),
      redoOfAttemptId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}redo_of_attempt_id'],
      ),
      userAnswer: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_answer'],
      ),
      solution: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}solution'],
      ),
      isCorrect: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_correct'],
      ),
      independent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}independent'],
      ),
      delayed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}delayed'],
      )!,
      helpJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}help_json'],
      ),
      feedback: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}feedback'],
      ),
      submittedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}submitted_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AttemptsTable createAlias(String alias) {
    return $AttemptsTable(attachedDatabase, alias);
  }
}

class AttemptRow extends DataClass implements Insertable<AttemptRow> {
  final String id;
  final String conversationId;
  final String? sessionId;
  final String? redoOfAttemptId;
  final String? userAnswer;
  final String? solution;
  final bool? isCorrect;
  final bool? independent;
  final bool delayed;
  final String? helpJson;
  final String? feedback;
  final String? submittedAt;
  final String createdAt;
  final String updatedAt;
  const AttemptRow({
    required this.id,
    required this.conversationId,
    this.sessionId,
    this.redoOfAttemptId,
    this.userAnswer,
    this.solution,
    this.isCorrect,
    this.independent,
    required this.delayed,
    this.helpJson,
    this.feedback,
    this.submittedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || sessionId != null) {
      map['session_id'] = Variable<String>(sessionId);
    }
    if (!nullToAbsent || redoOfAttemptId != null) {
      map['redo_of_attempt_id'] = Variable<String>(redoOfAttemptId);
    }
    if (!nullToAbsent || userAnswer != null) {
      map['user_answer'] = Variable<String>(userAnswer);
    }
    if (!nullToAbsent || solution != null) {
      map['solution'] = Variable<String>(solution);
    }
    if (!nullToAbsent || isCorrect != null) {
      map['is_correct'] = Variable<bool>(isCorrect);
    }
    if (!nullToAbsent || independent != null) {
      map['independent'] = Variable<bool>(independent);
    }
    map['delayed'] = Variable<bool>(delayed);
    if (!nullToAbsent || helpJson != null) {
      map['help_json'] = Variable<String>(helpJson);
    }
    if (!nullToAbsent || feedback != null) {
      map['feedback'] = Variable<String>(feedback);
    }
    if (!nullToAbsent || submittedAt != null) {
      map['submitted_at'] = Variable<String>(submittedAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  AttemptsCompanion toCompanion(bool nullToAbsent) {
    return AttemptsCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      sessionId: sessionId == null && nullToAbsent
          ? const Value.absent()
          : Value(sessionId),
      redoOfAttemptId: redoOfAttemptId == null && nullToAbsent
          ? const Value.absent()
          : Value(redoOfAttemptId),
      userAnswer: userAnswer == null && nullToAbsent
          ? const Value.absent()
          : Value(userAnswer),
      solution: solution == null && nullToAbsent
          ? const Value.absent()
          : Value(solution),
      isCorrect: isCorrect == null && nullToAbsent
          ? const Value.absent()
          : Value(isCorrect),
      independent: independent == null && nullToAbsent
          ? const Value.absent()
          : Value(independent),
      delayed: Value(delayed),
      helpJson: helpJson == null && nullToAbsent
          ? const Value.absent()
          : Value(helpJson),
      feedback: feedback == null && nullToAbsent
          ? const Value.absent()
          : Value(feedback),
      submittedAt: submittedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(submittedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory AttemptRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AttemptRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      sessionId: serializer.fromJson<String?>(json['sessionId']),
      redoOfAttemptId: serializer.fromJson<String?>(json['redoOfAttemptId']),
      userAnswer: serializer.fromJson<String?>(json['userAnswer']),
      solution: serializer.fromJson<String?>(json['solution']),
      isCorrect: serializer.fromJson<bool?>(json['isCorrect']),
      independent: serializer.fromJson<bool?>(json['independent']),
      delayed: serializer.fromJson<bool>(json['delayed']),
      helpJson: serializer.fromJson<String?>(json['helpJson']),
      feedback: serializer.fromJson<String?>(json['feedback']),
      submittedAt: serializer.fromJson<String?>(json['submittedAt']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'sessionId': serializer.toJson<String?>(sessionId),
      'redoOfAttemptId': serializer.toJson<String?>(redoOfAttemptId),
      'userAnswer': serializer.toJson<String?>(userAnswer),
      'solution': serializer.toJson<String?>(solution),
      'isCorrect': serializer.toJson<bool?>(isCorrect),
      'independent': serializer.toJson<bool?>(independent),
      'delayed': serializer.toJson<bool>(delayed),
      'helpJson': serializer.toJson<String?>(helpJson),
      'feedback': serializer.toJson<String?>(feedback),
      'submittedAt': serializer.toJson<String?>(submittedAt),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  AttemptRow copyWith({
    String? id,
    String? conversationId,
    Value<String?> sessionId = const Value.absent(),
    Value<String?> redoOfAttemptId = const Value.absent(),
    Value<String?> userAnswer = const Value.absent(),
    Value<String?> solution = const Value.absent(),
    Value<bool?> isCorrect = const Value.absent(),
    Value<bool?> independent = const Value.absent(),
    bool? delayed,
    Value<String?> helpJson = const Value.absent(),
    Value<String?> feedback = const Value.absent(),
    Value<String?> submittedAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => AttemptRow(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    sessionId: sessionId.present ? sessionId.value : this.sessionId,
    redoOfAttemptId: redoOfAttemptId.present
        ? redoOfAttemptId.value
        : this.redoOfAttemptId,
    userAnswer: userAnswer.present ? userAnswer.value : this.userAnswer,
    solution: solution.present ? solution.value : this.solution,
    isCorrect: isCorrect.present ? isCorrect.value : this.isCorrect,
    independent: independent.present ? independent.value : this.independent,
    delayed: delayed ?? this.delayed,
    helpJson: helpJson.present ? helpJson.value : this.helpJson,
    feedback: feedback.present ? feedback.value : this.feedback,
    submittedAt: submittedAt.present ? submittedAt.value : this.submittedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AttemptRow copyWithCompanion(AttemptsCompanion data) {
    return AttemptRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      redoOfAttemptId: data.redoOfAttemptId.present
          ? data.redoOfAttemptId.value
          : this.redoOfAttemptId,
      userAnswer: data.userAnswer.present
          ? data.userAnswer.value
          : this.userAnswer,
      solution: data.solution.present ? data.solution.value : this.solution,
      isCorrect: data.isCorrect.present ? data.isCorrect.value : this.isCorrect,
      independent: data.independent.present
          ? data.independent.value
          : this.independent,
      delayed: data.delayed.present ? data.delayed.value : this.delayed,
      helpJson: data.helpJson.present ? data.helpJson.value : this.helpJson,
      feedback: data.feedback.present ? data.feedback.value : this.feedback,
      submittedAt: data.submittedAt.present
          ? data.submittedAt.value
          : this.submittedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AttemptRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('sessionId: $sessionId, ')
          ..write('redoOfAttemptId: $redoOfAttemptId, ')
          ..write('userAnswer: $userAnswer, ')
          ..write('solution: $solution, ')
          ..write('isCorrect: $isCorrect, ')
          ..write('independent: $independent, ')
          ..write('delayed: $delayed, ')
          ..write('helpJson: $helpJson, ')
          ..write('feedback: $feedback, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    sessionId,
    redoOfAttemptId,
    userAnswer,
    solution,
    isCorrect,
    independent,
    delayed,
    helpJson,
    feedback,
    submittedAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AttemptRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.sessionId == this.sessionId &&
          other.redoOfAttemptId == this.redoOfAttemptId &&
          other.userAnswer == this.userAnswer &&
          other.solution == this.solution &&
          other.isCorrect == this.isCorrect &&
          other.independent == this.independent &&
          other.delayed == this.delayed &&
          other.helpJson == this.helpJson &&
          other.feedback == this.feedback &&
          other.submittedAt == this.submittedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class AttemptsCompanion extends UpdateCompanion<AttemptRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String?> sessionId;
  final Value<String?> redoOfAttemptId;
  final Value<String?> userAnswer;
  final Value<String?> solution;
  final Value<bool?> isCorrect;
  final Value<bool?> independent;
  final Value<bool> delayed;
  final Value<String?> helpJson;
  final Value<String?> feedback;
  final Value<String?> submittedAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const AttemptsCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.redoOfAttemptId = const Value.absent(),
    this.userAnswer = const Value.absent(),
    this.solution = const Value.absent(),
    this.isCorrect = const Value.absent(),
    this.independent = const Value.absent(),
    this.delayed = const Value.absent(),
    this.helpJson = const Value.absent(),
    this.feedback = const Value.absent(),
    this.submittedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttemptsCompanion.insert({
    required String id,
    required String conversationId,
    this.sessionId = const Value.absent(),
    this.redoOfAttemptId = const Value.absent(),
    this.userAnswer = const Value.absent(),
    this.solution = const Value.absent(),
    this.isCorrect = const Value.absent(),
    this.independent = const Value.absent(),
    this.delayed = const Value.absent(),
    this.helpJson = const Value.absent(),
    this.feedback = const Value.absent(),
    this.submittedAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       conversationId = Value(conversationId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<AttemptRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? sessionId,
    Expression<String>? redoOfAttemptId,
    Expression<String>? userAnswer,
    Expression<String>? solution,
    Expression<bool>? isCorrect,
    Expression<bool>? independent,
    Expression<bool>? delayed,
    Expression<String>? helpJson,
    Expression<String>? feedback,
    Expression<String>? submittedAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (sessionId != null) 'session_id': sessionId,
      if (redoOfAttemptId != null) 'redo_of_attempt_id': redoOfAttemptId,
      if (userAnswer != null) 'user_answer': userAnswer,
      if (solution != null) 'solution': solution,
      if (isCorrect != null) 'is_correct': isCorrect,
      if (independent != null) 'independent': independent,
      if (delayed != null) 'delayed': delayed,
      if (helpJson != null) 'help_json': helpJson,
      if (feedback != null) 'feedback': feedback,
      if (submittedAt != null) 'submitted_at': submittedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttemptsCompanion copyWith({
    Value<String>? id,
    Value<String>? conversationId,
    Value<String?>? sessionId,
    Value<String?>? redoOfAttemptId,
    Value<String?>? userAnswer,
    Value<String?>? solution,
    Value<bool?>? isCorrect,
    Value<bool?>? independent,
    Value<bool>? delayed,
    Value<String?>? helpJson,
    Value<String?>? feedback,
    Value<String?>? submittedAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return AttemptsCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      sessionId: sessionId ?? this.sessionId,
      redoOfAttemptId: redoOfAttemptId ?? this.redoOfAttemptId,
      userAnswer: userAnswer ?? this.userAnswer,
      solution: solution ?? this.solution,
      isCorrect: isCorrect ?? this.isCorrect,
      independent: independent ?? this.independent,
      delayed: delayed ?? this.delayed,
      helpJson: helpJson ?? this.helpJson,
      feedback: feedback ?? this.feedback,
      submittedAt: submittedAt ?? this.submittedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (redoOfAttemptId.present) {
      map['redo_of_attempt_id'] = Variable<String>(redoOfAttemptId.value);
    }
    if (userAnswer.present) {
      map['user_answer'] = Variable<String>(userAnswer.value);
    }
    if (solution.present) {
      map['solution'] = Variable<String>(solution.value);
    }
    if (isCorrect.present) {
      map['is_correct'] = Variable<bool>(isCorrect.value);
    }
    if (independent.present) {
      map['independent'] = Variable<bool>(independent.value);
    }
    if (delayed.present) {
      map['delayed'] = Variable<bool>(delayed.value);
    }
    if (helpJson.present) {
      map['help_json'] = Variable<String>(helpJson.value);
    }
    if (feedback.present) {
      map['feedback'] = Variable<String>(feedback.value);
    }
    if (submittedAt.present) {
      map['submitted_at'] = Variable<String>(submittedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttemptsCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('sessionId: $sessionId, ')
          ..write('redoOfAttemptId: $redoOfAttemptId, ')
          ..write('userAnswer: $userAnswer, ')
          ..write('solution: $solution, ')
          ..write('isCorrect: $isCorrect, ')
          ..write('independent: $independent, ')
          ..write('delayed: $delayed, ')
          ..write('helpJson: $helpJson, ')
          ..write('feedback: $feedback, ')
          ..write('submittedAt: $submittedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AssessmentsTable extends Assessments
    with TableInfo<$AssessmentsTable, AssessmentRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AssessmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptIdMeta = const VerificationMeta(
    'attemptId',
  );
  @override
  late final GeneratedColumn<String> attemptId = GeneratedColumn<String>(
    'attempt_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES attempt (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    check: () => kind.isIn(assessmentKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultMeta = const VerificationMeta('result');
  @override
  late final GeneratedColumn<String> result = GeneratedColumn<String>(
    'result',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _basisMeta = const VerificationMeta('basis');
  @override
  late final GeneratedColumn<String> basis = GeneratedColumn<String>(
    'basis',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    attemptId,
    kind,
    result,
    basis,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'assessment';
  @override
  VerificationContext validateIntegrity(
    Insertable<AssessmentRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('attempt_id')) {
      context.handle(
        _attemptIdMeta,
        attemptId.isAcceptableOrUnknown(data['attempt_id']!, _attemptIdMeta),
      );
    } else if (isInserting) {
      context.missing(_attemptIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('result')) {
      context.handle(
        _resultMeta,
        result.isAcceptableOrUnknown(data['result']!, _resultMeta),
      );
    } else if (isInserting) {
      context.missing(_resultMeta);
    }
    if (data.containsKey('basis')) {
      context.handle(
        _basisMeta,
        basis.isAcceptableOrUnknown(data['basis']!, _basisMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AssessmentRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AssessmentRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      attemptId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attempt_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      result: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result'],
      )!,
      basis: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}basis'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AssessmentsTable createAlias(String alias) {
    return $AssessmentsTable(attachedDatabase, alias);
  }
}

class AssessmentRow extends DataClass implements Insertable<AssessmentRow> {
  final String id;
  final String attemptId;
  final String kind;
  final String result;
  final String? basis;
  final String createdAt;
  final String updatedAt;
  const AssessmentRow({
    required this.id,
    required this.attemptId,
    required this.kind,
    required this.result,
    this.basis,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['attempt_id'] = Variable<String>(attemptId);
    map['kind'] = Variable<String>(kind);
    map['result'] = Variable<String>(result);
    if (!nullToAbsent || basis != null) {
      map['basis'] = Variable<String>(basis);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  AssessmentsCompanion toCompanion(bool nullToAbsent) {
    return AssessmentsCompanion(
      id: Value(id),
      attemptId: Value(attemptId),
      kind: Value(kind),
      result: Value(result),
      basis: basis == null && nullToAbsent
          ? const Value.absent()
          : Value(basis),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory AssessmentRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AssessmentRow(
      id: serializer.fromJson<String>(json['id']),
      attemptId: serializer.fromJson<String>(json['attemptId']),
      kind: serializer.fromJson<String>(json['kind']),
      result: serializer.fromJson<String>(json['result']),
      basis: serializer.fromJson<String?>(json['basis']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'attemptId': serializer.toJson<String>(attemptId),
      'kind': serializer.toJson<String>(kind),
      'result': serializer.toJson<String>(result),
      'basis': serializer.toJson<String?>(basis),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  AssessmentRow copyWith({
    String? id,
    String? attemptId,
    String? kind,
    String? result,
    Value<String?> basis = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => AssessmentRow(
    id: id ?? this.id,
    attemptId: attemptId ?? this.attemptId,
    kind: kind ?? this.kind,
    result: result ?? this.result,
    basis: basis.present ? basis.value : this.basis,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AssessmentRow copyWithCompanion(AssessmentsCompanion data) {
    return AssessmentRow(
      id: data.id.present ? data.id.value : this.id,
      attemptId: data.attemptId.present ? data.attemptId.value : this.attemptId,
      kind: data.kind.present ? data.kind.value : this.kind,
      result: data.result.present ? data.result.value : this.result,
      basis: data.basis.present ? data.basis.value : this.basis,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AssessmentRow(')
          ..write('id: $id, ')
          ..write('attemptId: $attemptId, ')
          ..write('kind: $kind, ')
          ..write('result: $result, ')
          ..write('basis: $basis, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, attemptId, kind, result, basis, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AssessmentRow &&
          other.id == this.id &&
          other.attemptId == this.attemptId &&
          other.kind == this.kind &&
          other.result == this.result &&
          other.basis == this.basis &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class AssessmentsCompanion extends UpdateCompanion<AssessmentRow> {
  final Value<String> id;
  final Value<String> attemptId;
  final Value<String> kind;
  final Value<String> result;
  final Value<String?> basis;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const AssessmentsCompanion({
    this.id = const Value.absent(),
    this.attemptId = const Value.absent(),
    this.kind = const Value.absent(),
    this.result = const Value.absent(),
    this.basis = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AssessmentsCompanion.insert({
    required String id,
    required String attemptId,
    required String kind,
    required String result,
    this.basis = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       attemptId = Value(attemptId),
       kind = Value(kind),
       result = Value(result),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<AssessmentRow> custom({
    Expression<String>? id,
    Expression<String>? attemptId,
    Expression<String>? kind,
    Expression<String>? result,
    Expression<String>? basis,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (attemptId != null) 'attempt_id': attemptId,
      if (kind != null) 'kind': kind,
      if (result != null) 'result': result,
      if (basis != null) 'basis': basis,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AssessmentsCompanion copyWith({
    Value<String>? id,
    Value<String>? attemptId,
    Value<String>? kind,
    Value<String>? result,
    Value<String?>? basis,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return AssessmentsCompanion(
      id: id ?? this.id,
      attemptId: attemptId ?? this.attemptId,
      kind: kind ?? this.kind,
      result: result ?? this.result,
      basis: basis ?? this.basis,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (attemptId.present) {
      map['attempt_id'] = Variable<String>(attemptId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (result.present) {
      map['result'] = Variable<String>(result.value);
    }
    if (basis.present) {
      map['basis'] = Variable<String>(basis.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AssessmentsCompanion(')
          ..write('id: $id, ')
          ..write('attemptId: $attemptId, ')
          ..write('kind: $kind, ')
          ..write('result: $result, ')
          ..write('basis: $basis, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MemoriesTable extends Memories
    with TableInfo<$MemoriesTable, MemoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MemoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    check: () => kind.isIn(memoryKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  @override
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
    'scope',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceKindMeta = const VerificationMeta(
    'sourceKind',
  );
  @override
  late final GeneratedColumn<String> sourceKind = GeneratedColumn<String>(
    'source_kind',
    aliasedName,
    false,
    check: () => sourceKind.isIn(memorySourceKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _validUntilMeta = const VerificationMeta(
    'validUntil',
  );
  @override
  late final GeneratedColumn<String> validUntil = GeneratedColumn<String>(
    'valid_until',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    check: () => status.isIn(memoryStatuses),
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    content,
    scope,
    sourceKind,
    sourceId,
    validUntil,
    status,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'memory';
  @override
  VerificationContext validateIntegrity(
    Insertable<MemoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('scope')) {
      context.handle(
        _scopeMeta,
        scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta),
      );
    }
    if (data.containsKey('source_kind')) {
      context.handle(
        _sourceKindMeta,
        sourceKind.isAcceptableOrUnknown(data['source_kind']!, _sourceKindMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceKindMeta);
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    }
    if (data.containsKey('valid_until')) {
      context.handle(
        _validUntilMeta,
        validUntil.isAcceptableOrUnknown(data['valid_until']!, _validUntilMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MemoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MemoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      scope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope'],
      ),
      sourceKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_kind'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      ),
      validUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}valid_until'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MemoriesTable createAlias(String alias) {
    return $MemoriesTable(attachedDatabase, alias);
  }
}

class MemoryRow extends DataClass implements Insertable<MemoryRow> {
  final String id;
  final String kind;
  final String content;
  final String? scope;
  final String sourceKind;
  final String? sourceId;
  final String? validUntil;
  final String status;
  final String createdAt;
  final String updatedAt;
  const MemoryRow({
    required this.id,
    required this.kind,
    required this.content,
    this.scope,
    required this.sourceKind,
    this.sourceId,
    this.validUntil,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['content'] = Variable<String>(content);
    if (!nullToAbsent || scope != null) {
      map['scope'] = Variable<String>(scope);
    }
    map['source_kind'] = Variable<String>(sourceKind);
    if (!nullToAbsent || sourceId != null) {
      map['source_id'] = Variable<String>(sourceId);
    }
    if (!nullToAbsent || validUntil != null) {
      map['valid_until'] = Variable<String>(validUntil);
    }
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  MemoriesCompanion toCompanion(bool nullToAbsent) {
    return MemoriesCompanion(
      id: Value(id),
      kind: Value(kind),
      content: Value(content),
      scope: scope == null && nullToAbsent
          ? const Value.absent()
          : Value(scope),
      sourceKind: Value(sourceKind),
      sourceId: sourceId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceId),
      validUntil: validUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(validUntil),
      status: Value(status),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory MemoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MemoryRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      content: serializer.fromJson<String>(json['content']),
      scope: serializer.fromJson<String?>(json['scope']),
      sourceKind: serializer.fromJson<String>(json['sourceKind']),
      sourceId: serializer.fromJson<String?>(json['sourceId']),
      validUntil: serializer.fromJson<String?>(json['validUntil']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'content': serializer.toJson<String>(content),
      'scope': serializer.toJson<String?>(scope),
      'sourceKind': serializer.toJson<String>(sourceKind),
      'sourceId': serializer.toJson<String?>(sourceId),
      'validUntil': serializer.toJson<String?>(validUntil),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  MemoryRow copyWith({
    String? id,
    String? kind,
    String? content,
    Value<String?> scope = const Value.absent(),
    String? sourceKind,
    Value<String?> sourceId = const Value.absent(),
    Value<String?> validUntil = const Value.absent(),
    String? status,
    String? createdAt,
    String? updatedAt,
  }) => MemoryRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    content: content ?? this.content,
    scope: scope.present ? scope.value : this.scope,
    sourceKind: sourceKind ?? this.sourceKind,
    sourceId: sourceId.present ? sourceId.value : this.sourceId,
    validUntil: validUntil.present ? validUntil.value : this.validUntil,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MemoryRow copyWithCompanion(MemoriesCompanion data) {
    return MemoryRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      content: data.content.present ? data.content.value : this.content,
      scope: data.scope.present ? data.scope.value : this.scope,
      sourceKind: data.sourceKind.present
          ? data.sourceKind.value
          : this.sourceKind,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      validUntil: data.validUntil.present
          ? data.validUntil.value
          : this.validUntil,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MemoryRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('content: $content, ')
          ..write('scope: $scope, ')
          ..write('sourceKind: $sourceKind, ')
          ..write('sourceId: $sourceId, ')
          ..write('validUntil: $validUntil, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    content,
    scope,
    sourceKind,
    sourceId,
    validUntil,
    status,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemoryRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.content == this.content &&
          other.scope == this.scope &&
          other.sourceKind == this.sourceKind &&
          other.sourceId == this.sourceId &&
          other.validUntil == this.validUntil &&
          other.status == this.status &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class MemoriesCompanion extends UpdateCompanion<MemoryRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> content;
  final Value<String?> scope;
  final Value<String> sourceKind;
  final Value<String?> sourceId;
  final Value<String?> validUntil;
  final Value<String> status;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const MemoriesCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.content = const Value.absent(),
    this.scope = const Value.absent(),
    this.sourceKind = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.validUntil = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MemoriesCompanion.insert({
    required String id,
    required String kind,
    required String content,
    this.scope = const Value.absent(),
    required String sourceKind,
    this.sourceId = const Value.absent(),
    this.validUntil = const Value.absent(),
    this.status = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       content = Value(content),
       sourceKind = Value(sourceKind),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<MemoryRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? content,
    Expression<String>? scope,
    Expression<String>? sourceKind,
    Expression<String>? sourceId,
    Expression<String>? validUntil,
    Expression<String>? status,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (content != null) 'content': content,
      if (scope != null) 'scope': scope,
      if (sourceKind != null) 'source_kind': sourceKind,
      if (sourceId != null) 'source_id': sourceId,
      if (validUntil != null) 'valid_until': validUntil,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MemoriesCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? content,
    Value<String?>? scope,
    Value<String>? sourceKind,
    Value<String?>? sourceId,
    Value<String?>? validUntil,
    Value<String>? status,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return MemoriesCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      content: content ?? this.content,
      scope: scope ?? this.scope,
      sourceKind: sourceKind ?? this.sourceKind,
      sourceId: sourceId ?? this.sourceId,
      validUntil: validUntil ?? this.validUntil,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (sourceKind.present) {
      map['source_kind'] = Variable<String>(sourceKind.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (validUntil.present) {
      map['valid_until'] = Variable<String>(validUntil.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MemoriesCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('content: $content, ')
          ..write('scope: $scope, ')
          ..write('sourceKind: $sourceKind, ')
          ..write('sourceId: $sourceId, ')
          ..write('validUntil: $validUntil, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RevisionCommitsTable extends RevisionCommits
    with TableInfo<$RevisionCommitsTable, RevisionCommitRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionCommitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES revision_commit (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actorMeta = const VerificationMeta('actor');
  @override
  late final GeneratedColumn<String> actor = GeneratedColumn<String>(
    'actor',
    aliasedName,
    false,
    check: () => actor.isIn(revisionActors),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
    'action',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _requestIdMeta = const VerificationMeta(
    'requestId',
  );
  @override
  late final GeneratedColumn<String> requestId = GeneratedColumn<String>(
    'request_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _restoredCommitIdMeta = const VerificationMeta(
    'restoredCommitId',
  );
  @override
  late final GeneratedColumn<int> restoredCommitId = GeneratedColumn<int>(
    'restored_commit_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _revertedCommitIdMeta = const VerificationMeta(
    'revertedCommitId',
  );
  @override
  late final GeneratedColumn<int> revertedCommitId = GeneratedColumn<int>(
    'reverted_commit_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _changeCountMeta = const VerificationMeta(
    'changeCount',
  );
  @override
  late final GeneratedColumn<int> changeCount = GeneratedColumn<int>(
    'change_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    parentId,
    generation,
    actor,
    action,
    requestId,
    restoredCommitId,
    revertedCommitId,
    changeCount,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_commit';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionCommitRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('actor')) {
      context.handle(
        _actorMeta,
        actor.isAcceptableOrUnknown(data['actor']!, _actorMeta),
      );
    } else if (isInserting) {
      context.missing(_actorMeta);
    }
    if (data.containsKey('action')) {
      context.handle(
        _actionMeta,
        action.isAcceptableOrUnknown(data['action']!, _actionMeta),
      );
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('request_id')) {
      context.handle(
        _requestIdMeta,
        requestId.isAcceptableOrUnknown(data['request_id']!, _requestIdMeta),
      );
    }
    if (data.containsKey('restored_commit_id')) {
      context.handle(
        _restoredCommitIdMeta,
        restoredCommitId.isAcceptableOrUnknown(
          data['restored_commit_id']!,
          _restoredCommitIdMeta,
        ),
      );
    }
    if (data.containsKey('reverted_commit_id')) {
      context.handle(
        _revertedCommitIdMeta,
        revertedCommitId.isAcceptableOrUnknown(
          data['reverted_commit_id']!,
          _revertedCommitIdMeta,
        ),
      );
    }
    if (data.containsKey('change_count')) {
      context.handle(
        _changeCountMeta,
        changeCount.isAcceptableOrUnknown(
          data['change_count']!,
          _changeCountMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RevisionCommitRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionCommitRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      actor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}actor'],
      )!,
      action: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action'],
      )!,
      requestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_id'],
      ),
      restoredCommitId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}restored_commit_id'],
      ),
      revertedCommitId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reverted_commit_id'],
      ),
      changeCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}change_count'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $RevisionCommitsTable createAlias(String alias) {
    return $RevisionCommitsTable(attachedDatabase, alias);
  }
}

class RevisionCommitRow extends DataClass
    implements Insertable<RevisionCommitRow> {
  final int id;
  final int? parentId;
  final int generation;
  final String actor;
  final String action;
  final String? requestId;
  final int? restoredCommitId;
  final int? revertedCommitId;
  final int changeCount;
  final String createdAt;
  const RevisionCommitRow({
    required this.id,
    this.parentId,
    required this.generation,
    required this.actor,
    required this.action,
    this.requestId,
    this.restoredCommitId,
    this.revertedCommitId,
    required this.changeCount,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['generation'] = Variable<int>(generation);
    map['actor'] = Variable<String>(actor);
    map['action'] = Variable<String>(action);
    if (!nullToAbsent || requestId != null) {
      map['request_id'] = Variable<String>(requestId);
    }
    if (!nullToAbsent || restoredCommitId != null) {
      map['restored_commit_id'] = Variable<int>(restoredCommitId);
    }
    if (!nullToAbsent || revertedCommitId != null) {
      map['reverted_commit_id'] = Variable<int>(revertedCommitId);
    }
    map['change_count'] = Variable<int>(changeCount);
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  RevisionCommitsCompanion toCompanion(bool nullToAbsent) {
    return RevisionCommitsCompanion(
      id: Value(id),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      generation: Value(generation),
      actor: Value(actor),
      action: Value(action),
      requestId: requestId == null && nullToAbsent
          ? const Value.absent()
          : Value(requestId),
      restoredCommitId: restoredCommitId == null && nullToAbsent
          ? const Value.absent()
          : Value(restoredCommitId),
      revertedCommitId: revertedCommitId == null && nullToAbsent
          ? const Value.absent()
          : Value(revertedCommitId),
      changeCount: Value(changeCount),
      createdAt: Value(createdAt),
    );
  }

  factory RevisionCommitRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionCommitRow(
      id: serializer.fromJson<int>(json['id']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      generation: serializer.fromJson<int>(json['generation']),
      actor: serializer.fromJson<String>(json['actor']),
      action: serializer.fromJson<String>(json['action']),
      requestId: serializer.fromJson<String?>(json['requestId']),
      restoredCommitId: serializer.fromJson<int?>(json['restoredCommitId']),
      revertedCommitId: serializer.fromJson<int?>(json['revertedCommitId']),
      changeCount: serializer.fromJson<int>(json['changeCount']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'parentId': serializer.toJson<int?>(parentId),
      'generation': serializer.toJson<int>(generation),
      'actor': serializer.toJson<String>(actor),
      'action': serializer.toJson<String>(action),
      'requestId': serializer.toJson<String?>(requestId),
      'restoredCommitId': serializer.toJson<int?>(restoredCommitId),
      'revertedCommitId': serializer.toJson<int?>(revertedCommitId),
      'changeCount': serializer.toJson<int>(changeCount),
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  RevisionCommitRow copyWith({
    int? id,
    Value<int?> parentId = const Value.absent(),
    int? generation,
    String? actor,
    String? action,
    Value<String?> requestId = const Value.absent(),
    Value<int?> restoredCommitId = const Value.absent(),
    Value<int?> revertedCommitId = const Value.absent(),
    int? changeCount,
    String? createdAt,
  }) => RevisionCommitRow(
    id: id ?? this.id,
    parentId: parentId.present ? parentId.value : this.parentId,
    generation: generation ?? this.generation,
    actor: actor ?? this.actor,
    action: action ?? this.action,
    requestId: requestId.present ? requestId.value : this.requestId,
    restoredCommitId: restoredCommitId.present
        ? restoredCommitId.value
        : this.restoredCommitId,
    revertedCommitId: revertedCommitId.present
        ? revertedCommitId.value
        : this.revertedCommitId,
    changeCount: changeCount ?? this.changeCount,
    createdAt: createdAt ?? this.createdAt,
  );
  RevisionCommitRow copyWithCompanion(RevisionCommitsCompanion data) {
    return RevisionCommitRow(
      id: data.id.present ? data.id.value : this.id,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      actor: data.actor.present ? data.actor.value : this.actor,
      action: data.action.present ? data.action.value : this.action,
      requestId: data.requestId.present ? data.requestId.value : this.requestId,
      restoredCommitId: data.restoredCommitId.present
          ? data.restoredCommitId.value
          : this.restoredCommitId,
      revertedCommitId: data.revertedCommitId.present
          ? data.revertedCommitId.value
          : this.revertedCommitId,
      changeCount: data.changeCount.present
          ? data.changeCount.value
          : this.changeCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionCommitRow(')
          ..write('id: $id, ')
          ..write('parentId: $parentId, ')
          ..write('generation: $generation, ')
          ..write('actor: $actor, ')
          ..write('action: $action, ')
          ..write('requestId: $requestId, ')
          ..write('restoredCommitId: $restoredCommitId, ')
          ..write('revertedCommitId: $revertedCommitId, ')
          ..write('changeCount: $changeCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    parentId,
    generation,
    actor,
    action,
    requestId,
    restoredCommitId,
    revertedCommitId,
    changeCount,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionCommitRow &&
          other.id == this.id &&
          other.parentId == this.parentId &&
          other.generation == this.generation &&
          other.actor == this.actor &&
          other.action == this.action &&
          other.requestId == this.requestId &&
          other.restoredCommitId == this.restoredCommitId &&
          other.revertedCommitId == this.revertedCommitId &&
          other.changeCount == this.changeCount &&
          other.createdAt == this.createdAt);
}

class RevisionCommitsCompanion extends UpdateCompanion<RevisionCommitRow> {
  final Value<int> id;
  final Value<int?> parentId;
  final Value<int> generation;
  final Value<String> actor;
  final Value<String> action;
  final Value<String?> requestId;
  final Value<int?> restoredCommitId;
  final Value<int?> revertedCommitId;
  final Value<int> changeCount;
  final Value<String> createdAt;
  const RevisionCommitsCompanion({
    this.id = const Value.absent(),
    this.parentId = const Value.absent(),
    this.generation = const Value.absent(),
    this.actor = const Value.absent(),
    this.action = const Value.absent(),
    this.requestId = const Value.absent(),
    this.restoredCommitId = const Value.absent(),
    this.revertedCommitId = const Value.absent(),
    this.changeCount = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  RevisionCommitsCompanion.insert({
    this.id = const Value.absent(),
    this.parentId = const Value.absent(),
    required int generation,
    required String actor,
    required String action,
    this.requestId = const Value.absent(),
    this.restoredCommitId = const Value.absent(),
    this.revertedCommitId = const Value.absent(),
    this.changeCount = const Value.absent(),
    required String createdAt,
  }) : generation = Value(generation),
       actor = Value(actor),
       action = Value(action),
       createdAt = Value(createdAt);
  static Insertable<RevisionCommitRow> custom({
    Expression<int>? id,
    Expression<int>? parentId,
    Expression<int>? generation,
    Expression<String>? actor,
    Expression<String>? action,
    Expression<String>? requestId,
    Expression<int>? restoredCommitId,
    Expression<int>? revertedCommitId,
    Expression<int>? changeCount,
    Expression<String>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (parentId != null) 'parent_id': parentId,
      if (generation != null) 'generation': generation,
      if (actor != null) 'actor': actor,
      if (action != null) 'action': action,
      if (requestId != null) 'request_id': requestId,
      if (restoredCommitId != null) 'restored_commit_id': restoredCommitId,
      if (revertedCommitId != null) 'reverted_commit_id': revertedCommitId,
      if (changeCount != null) 'change_count': changeCount,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  RevisionCommitsCompanion copyWith({
    Value<int>? id,
    Value<int?>? parentId,
    Value<int>? generation,
    Value<String>? actor,
    Value<String>? action,
    Value<String?>? requestId,
    Value<int?>? restoredCommitId,
    Value<int?>? revertedCommitId,
    Value<int>? changeCount,
    Value<String>? createdAt,
  }) {
    return RevisionCommitsCompanion(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      generation: generation ?? this.generation,
      actor: actor ?? this.actor,
      action: action ?? this.action,
      requestId: requestId ?? this.requestId,
      restoredCommitId: restoredCommitId ?? this.restoredCommitId,
      revertedCommitId: revertedCommitId ?? this.revertedCommitId,
      changeCount: changeCount ?? this.changeCount,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (actor.present) {
      map['actor'] = Variable<String>(actor.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (requestId.present) {
      map['request_id'] = Variable<String>(requestId.value);
    }
    if (restoredCommitId.present) {
      map['restored_commit_id'] = Variable<int>(restoredCommitId.value);
    }
    if (revertedCommitId.present) {
      map['reverted_commit_id'] = Variable<int>(revertedCommitId.value);
    }
    if (changeCount.present) {
      map['change_count'] = Variable<int>(changeCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionCommitsCompanion(')
          ..write('id: $id, ')
          ..write('parentId: $parentId, ')
          ..write('generation: $generation, ')
          ..write('actor: $actor, ')
          ..write('action: $action, ')
          ..write('requestId: $requestId, ')
          ..write('restoredCommitId: $restoredCommitId, ')
          ..write('revertedCommitId: $revertedCommitId, ')
          ..write('changeCount: $changeCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $RevisionChangesTable extends RevisionChanges
    with TableInfo<$RevisionChangesTable, RevisionChangeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionChangesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _commitIdMeta = const VerificationMeta(
    'commitId',
  );
  @override
  late final GeneratedColumn<int> commitId = GeneratedColumn<int>(
    'commit_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES revision_commit (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _targetTableMeta = const VerificationMeta(
    'targetTable',
  );
  @override
  late final GeneratedColumn<String> targetTable = GeneratedColumn<String>(
    'table_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rowKeyMeta = const VerificationMeta('rowKey');
  @override
  late final GeneratedColumn<String> rowKey = GeneratedColumn<String>(
    'row_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    check: () => op.isIn(changeOperations),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _beforeJsonMeta = const VerificationMeta(
    'beforeJson',
  );
  @override
  late final GeneratedColumn<String> beforeJson = GeneratedColumn<String>(
    'before_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _afterJsonMeta = const VerificationMeta(
    'afterJson',
  );
  @override
  late final GeneratedColumn<String> afterJson = GeneratedColumn<String>(
    'after_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    commitId,
    seq,
    targetTable,
    rowKey,
    op,
    beforeJson,
    afterJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_change';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionChangeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('commit_id')) {
      context.handle(
        _commitIdMeta,
        commitId.isAcceptableOrUnknown(data['commit_id']!, _commitIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commitIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('table_name')) {
      context.handle(
        _targetTableMeta,
        targetTable.isAcceptableOrUnknown(
          data['table_name']!,
          _targetTableMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_targetTableMeta);
    }
    if (data.containsKey('row_key')) {
      context.handle(
        _rowKeyMeta,
        rowKey.isAcceptableOrUnknown(data['row_key']!, _rowKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_rowKeyMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('before_json')) {
      context.handle(
        _beforeJsonMeta,
        beforeJson.isAcceptableOrUnknown(data['before_json']!, _beforeJsonMeta),
      );
    }
    if (data.containsKey('after_json')) {
      context.handle(
        _afterJsonMeta,
        afterJson.isAcceptableOrUnknown(data['after_json']!, _afterJsonMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {commitId, seq};
  @override
  RevisionChangeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionChangeRow(
      commitId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}commit_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      targetTable: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}table_name'],
      )!,
      rowKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}row_key'],
      )!,
      op: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op'],
      )!,
      beforeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}before_json'],
      ),
      afterJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}after_json'],
      ),
    );
  }

  @override
  $RevisionChangesTable createAlias(String alias) {
    return $RevisionChangesTable(attachedDatabase, alias);
  }
}

class RevisionChangeRow extends DataClass
    implements Insertable<RevisionChangeRow> {
  final int commitId;
  final int seq;
  final String targetTable;
  final String rowKey;
  final String op;
  final String? beforeJson;
  final String? afterJson;
  const RevisionChangeRow({
    required this.commitId,
    required this.seq,
    required this.targetTable,
    required this.rowKey,
    required this.op,
    this.beforeJson,
    this.afterJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['commit_id'] = Variable<int>(commitId);
    map['seq'] = Variable<int>(seq);
    map['table_name'] = Variable<String>(targetTable);
    map['row_key'] = Variable<String>(rowKey);
    map['op'] = Variable<String>(op);
    if (!nullToAbsent || beforeJson != null) {
      map['before_json'] = Variable<String>(beforeJson);
    }
    if (!nullToAbsent || afterJson != null) {
      map['after_json'] = Variable<String>(afterJson);
    }
    return map;
  }

  RevisionChangesCompanion toCompanion(bool nullToAbsent) {
    return RevisionChangesCompanion(
      commitId: Value(commitId),
      seq: Value(seq),
      targetTable: Value(targetTable),
      rowKey: Value(rowKey),
      op: Value(op),
      beforeJson: beforeJson == null && nullToAbsent
          ? const Value.absent()
          : Value(beforeJson),
      afterJson: afterJson == null && nullToAbsent
          ? const Value.absent()
          : Value(afterJson),
    );
  }

  factory RevisionChangeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionChangeRow(
      commitId: serializer.fromJson<int>(json['commitId']),
      seq: serializer.fromJson<int>(json['seq']),
      targetTable: serializer.fromJson<String>(json['targetTable']),
      rowKey: serializer.fromJson<String>(json['rowKey']),
      op: serializer.fromJson<String>(json['op']),
      beforeJson: serializer.fromJson<String?>(json['beforeJson']),
      afterJson: serializer.fromJson<String?>(json['afterJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'commitId': serializer.toJson<int>(commitId),
      'seq': serializer.toJson<int>(seq),
      'targetTable': serializer.toJson<String>(targetTable),
      'rowKey': serializer.toJson<String>(rowKey),
      'op': serializer.toJson<String>(op),
      'beforeJson': serializer.toJson<String?>(beforeJson),
      'afterJson': serializer.toJson<String?>(afterJson),
    };
  }

  RevisionChangeRow copyWith({
    int? commitId,
    int? seq,
    String? targetTable,
    String? rowKey,
    String? op,
    Value<String?> beforeJson = const Value.absent(),
    Value<String?> afterJson = const Value.absent(),
  }) => RevisionChangeRow(
    commitId: commitId ?? this.commitId,
    seq: seq ?? this.seq,
    targetTable: targetTable ?? this.targetTable,
    rowKey: rowKey ?? this.rowKey,
    op: op ?? this.op,
    beforeJson: beforeJson.present ? beforeJson.value : this.beforeJson,
    afterJson: afterJson.present ? afterJson.value : this.afterJson,
  );
  RevisionChangeRow copyWithCompanion(RevisionChangesCompanion data) {
    return RevisionChangeRow(
      commitId: data.commitId.present ? data.commitId.value : this.commitId,
      seq: data.seq.present ? data.seq.value : this.seq,
      targetTable: data.targetTable.present
          ? data.targetTable.value
          : this.targetTable,
      rowKey: data.rowKey.present ? data.rowKey.value : this.rowKey,
      op: data.op.present ? data.op.value : this.op,
      beforeJson: data.beforeJson.present
          ? data.beforeJson.value
          : this.beforeJson,
      afterJson: data.afterJson.present ? data.afterJson.value : this.afterJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionChangeRow(')
          ..write('commitId: $commitId, ')
          ..write('seq: $seq, ')
          ..write('targetTable: $targetTable, ')
          ..write('rowKey: $rowKey, ')
          ..write('op: $op, ')
          ..write('beforeJson: $beforeJson, ')
          ..write('afterJson: $afterJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    commitId,
    seq,
    targetTable,
    rowKey,
    op,
    beforeJson,
    afterJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionChangeRow &&
          other.commitId == this.commitId &&
          other.seq == this.seq &&
          other.targetTable == this.targetTable &&
          other.rowKey == this.rowKey &&
          other.op == this.op &&
          other.beforeJson == this.beforeJson &&
          other.afterJson == this.afterJson);
}

class RevisionChangesCompanion extends UpdateCompanion<RevisionChangeRow> {
  final Value<int> commitId;
  final Value<int> seq;
  final Value<String> targetTable;
  final Value<String> rowKey;
  final Value<String> op;
  final Value<String?> beforeJson;
  final Value<String?> afterJson;
  final Value<int> rowid;
  const RevisionChangesCompanion({
    this.commitId = const Value.absent(),
    this.seq = const Value.absent(),
    this.targetTable = const Value.absent(),
    this.rowKey = const Value.absent(),
    this.op = const Value.absent(),
    this.beforeJson = const Value.absent(),
    this.afterJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RevisionChangesCompanion.insert({
    required int commitId,
    required int seq,
    required String targetTable,
    required String rowKey,
    required String op,
    this.beforeJson = const Value.absent(),
    this.afterJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : commitId = Value(commitId),
       seq = Value(seq),
       targetTable = Value(targetTable),
       rowKey = Value(rowKey),
       op = Value(op);
  static Insertable<RevisionChangeRow> custom({
    Expression<int>? commitId,
    Expression<int>? seq,
    Expression<String>? targetTable,
    Expression<String>? rowKey,
    Expression<String>? op,
    Expression<String>? beforeJson,
    Expression<String>? afterJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (commitId != null) 'commit_id': commitId,
      if (seq != null) 'seq': seq,
      if (targetTable != null) 'table_name': targetTable,
      if (rowKey != null) 'row_key': rowKey,
      if (op != null) 'op': op,
      if (beforeJson != null) 'before_json': beforeJson,
      if (afterJson != null) 'after_json': afterJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RevisionChangesCompanion copyWith({
    Value<int>? commitId,
    Value<int>? seq,
    Value<String>? targetTable,
    Value<String>? rowKey,
    Value<String>? op,
    Value<String?>? beforeJson,
    Value<String?>? afterJson,
    Value<int>? rowid,
  }) {
    return RevisionChangesCompanion(
      commitId: commitId ?? this.commitId,
      seq: seq ?? this.seq,
      targetTable: targetTable ?? this.targetTable,
      rowKey: rowKey ?? this.rowKey,
      op: op ?? this.op,
      beforeJson: beforeJson ?? this.beforeJson,
      afterJson: afterJson ?? this.afterJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (commitId.present) {
      map['commit_id'] = Variable<int>(commitId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (targetTable.present) {
      map['table_name'] = Variable<String>(targetTable.value);
    }
    if (rowKey.present) {
      map['row_key'] = Variable<String>(rowKey.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (beforeJson.present) {
      map['before_json'] = Variable<String>(beforeJson.value);
    }
    if (afterJson.present) {
      map['after_json'] = Variable<String>(afterJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionChangesCompanion(')
          ..write('commitId: $commitId, ')
          ..write('seq: $seq, ')
          ..write('targetTable: $targetTable, ')
          ..write('rowKey: $rowKey, ')
          ..write('op: $op, ')
          ..write('beforeJson: $beforeJson, ')
          ..write('afterJson: $afterJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RevisionRefsTable extends RevisionRefs
    with TableInfo<$RevisionRefsTable, RevisionRefRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionRefsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commitIdMeta = const VerificationMeta(
    'commitId',
  );
  @override
  late final GeneratedColumn<int> commitId = GeneratedColumn<int>(
    'commit_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    name,
    commitId,
    note,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_ref';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionRefRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('commit_id')) {
      context.handle(
        _commitIdMeta,
        commitId.isAcceptableOrUnknown(data['commit_id']!, _commitIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commitIdMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  RevisionRefRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionRefRow(
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      commitId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}commit_id'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $RevisionRefsTable createAlias(String alias) {
    return $RevisionRefsTable(attachedDatabase, alias);
  }
}

class RevisionRefRow extends DataClass implements Insertable<RevisionRefRow> {
  final String name;
  final int commitId;
  final String? note;
  final String createdAt;
  final String updatedAt;
  const RevisionRefRow({
    required this.name,
    required this.commitId,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['commit_id'] = Variable<int>(commitId);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  RevisionRefsCompanion toCompanion(bool nullToAbsent) {
    return RevisionRefsCompanion(
      name: Value(name),
      commitId: Value(commitId),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory RevisionRefRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionRefRow(
      name: serializer.fromJson<String>(json['name']),
      commitId: serializer.fromJson<int>(json['commitId']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'commitId': serializer.toJson<int>(commitId),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
    };
  }

  RevisionRefRow copyWith({
    String? name,
    int? commitId,
    Value<String?> note = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => RevisionRefRow(
    name: name ?? this.name,
    commitId: commitId ?? this.commitId,
    note: note.present ? note.value : this.note,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  RevisionRefRow copyWithCompanion(RevisionRefsCompanion data) {
    return RevisionRefRow(
      name: data.name.present ? data.name.value : this.name,
      commitId: data.commitId.present ? data.commitId.value : this.commitId,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionRefRow(')
          ..write('name: $name, ')
          ..write('commitId: $commitId, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, commitId, note, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionRefRow &&
          other.name == this.name &&
          other.commitId == this.commitId &&
          other.note == this.note &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class RevisionRefsCompanion extends UpdateCompanion<RevisionRefRow> {
  final Value<String> name;
  final Value<int> commitId;
  final Value<String?> note;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const RevisionRefsCompanion({
    this.name = const Value.absent(),
    this.commitId = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RevisionRefsCompanion.insert({
    required String name,
    required int commitId,
    this.note = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : name = Value(name),
       commitId = Value(commitId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<RevisionRefRow> custom({
    Expression<String>? name,
    Expression<int>? commitId,
    Expression<String>? note,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (commitId != null) 'commit_id': commitId,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RevisionRefsCompanion copyWith({
    Value<String>? name,
    Value<int>? commitId,
    Value<String?>? note,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return RevisionRefsCompanion(
      name: name ?? this.name,
      commitId: commitId ?? this.commitId,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (commitId.present) {
      map['commit_id'] = Variable<int>(commitId.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionRefsCompanion(')
          ..write('name: $name, ')
          ..write('commitId: $commitId, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RevisionCheckpointsTable extends RevisionCheckpoints
    with TableInfo<$RevisionCheckpointsTable, RevisionCheckpointRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionCheckpointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    check: () => kind.isIn(checkpointKinds),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commitIdMeta = const VerificationMeta(
    'commitId',
  );
  @override
  late final GeneratedColumn<int> commitId = GeneratedColumn<int>(
    'commit_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectionJsonMeta = const VerificationMeta(
    'projectionJson',
  );
  @override
  late final GeneratedColumn<String> projectionJson = GeneratedColumn<String>(
    'projection_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _assetHashesJsonMeta = const VerificationMeta(
    'assetHashesJson',
  );
  @override
  late final GeneratedColumn<String> assetHashesJson = GeneratedColumn<String>(
    'asset_hashes_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _checksumMeta = const VerificationMeta(
    'checksum',
  );
  @override
  late final GeneratedColumn<String> checksum = GeneratedColumn<String>(
    'checksum',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    commitId,
    projectionJson,
    assetHashesJson,
    checksum,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_checkpoint';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionCheckpointRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('commit_id')) {
      context.handle(
        _commitIdMeta,
        commitId.isAcceptableOrUnknown(data['commit_id']!, _commitIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commitIdMeta);
    }
    if (data.containsKey('projection_json')) {
      context.handle(
        _projectionJsonMeta,
        projectionJson.isAcceptableOrUnknown(
          data['projection_json']!,
          _projectionJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_projectionJsonMeta);
    }
    if (data.containsKey('asset_hashes_json')) {
      context.handle(
        _assetHashesJsonMeta,
        assetHashesJson.isAcceptableOrUnknown(
          data['asset_hashes_json']!,
          _assetHashesJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_assetHashesJsonMeta);
    }
    if (data.containsKey('checksum')) {
      context.handle(
        _checksumMeta,
        checksum.isAcceptableOrUnknown(data['checksum']!, _checksumMeta),
      );
    } else if (isInserting) {
      context.missing(_checksumMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RevisionCheckpointRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionCheckpointRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      commitId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}commit_id'],
      )!,
      projectionJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}projection_json'],
      )!,
      assetHashesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}asset_hashes_json'],
      )!,
      checksum: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}checksum'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $RevisionCheckpointsTable createAlias(String alias) {
    return $RevisionCheckpointsTable(attachedDatabase, alias);
  }
}

class RevisionCheckpointRow extends DataClass
    implements Insertable<RevisionCheckpointRow> {
  final int id;
  final String kind;
  final int commitId;
  final String projectionJson;
  final String assetHashesJson;
  final String checksum;
  final String createdAt;
  const RevisionCheckpointRow({
    required this.id,
    required this.kind,
    required this.commitId,
    required this.projectionJson,
    required this.assetHashesJson,
    required this.checksum,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['kind'] = Variable<String>(kind);
    map['commit_id'] = Variable<int>(commitId);
    map['projection_json'] = Variable<String>(projectionJson);
    map['asset_hashes_json'] = Variable<String>(assetHashesJson);
    map['checksum'] = Variable<String>(checksum);
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  RevisionCheckpointsCompanion toCompanion(bool nullToAbsent) {
    return RevisionCheckpointsCompanion(
      id: Value(id),
      kind: Value(kind),
      commitId: Value(commitId),
      projectionJson: Value(projectionJson),
      assetHashesJson: Value(assetHashesJson),
      checksum: Value(checksum),
      createdAt: Value(createdAt),
    );
  }

  factory RevisionCheckpointRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionCheckpointRow(
      id: serializer.fromJson<int>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      commitId: serializer.fromJson<int>(json['commitId']),
      projectionJson: serializer.fromJson<String>(json['projectionJson']),
      assetHashesJson: serializer.fromJson<String>(json['assetHashesJson']),
      checksum: serializer.fromJson<String>(json['checksum']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'kind': serializer.toJson<String>(kind),
      'commitId': serializer.toJson<int>(commitId),
      'projectionJson': serializer.toJson<String>(projectionJson),
      'assetHashesJson': serializer.toJson<String>(assetHashesJson),
      'checksum': serializer.toJson<String>(checksum),
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  RevisionCheckpointRow copyWith({
    int? id,
    String? kind,
    int? commitId,
    String? projectionJson,
    String? assetHashesJson,
    String? checksum,
    String? createdAt,
  }) => RevisionCheckpointRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    commitId: commitId ?? this.commitId,
    projectionJson: projectionJson ?? this.projectionJson,
    assetHashesJson: assetHashesJson ?? this.assetHashesJson,
    checksum: checksum ?? this.checksum,
    createdAt: createdAt ?? this.createdAt,
  );
  RevisionCheckpointRow copyWithCompanion(RevisionCheckpointsCompanion data) {
    return RevisionCheckpointRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      commitId: data.commitId.present ? data.commitId.value : this.commitId,
      projectionJson: data.projectionJson.present
          ? data.projectionJson.value
          : this.projectionJson,
      assetHashesJson: data.assetHashesJson.present
          ? data.assetHashesJson.value
          : this.assetHashesJson,
      checksum: data.checksum.present ? data.checksum.value : this.checksum,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionCheckpointRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('commitId: $commitId, ')
          ..write('projectionJson: $projectionJson, ')
          ..write('assetHashesJson: $assetHashesJson, ')
          ..write('checksum: $checksum, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    commitId,
    projectionJson,
    assetHashesJson,
    checksum,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionCheckpointRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.commitId == this.commitId &&
          other.projectionJson == this.projectionJson &&
          other.assetHashesJson == this.assetHashesJson &&
          other.checksum == this.checksum &&
          other.createdAt == this.createdAt);
}

class RevisionCheckpointsCompanion
    extends UpdateCompanion<RevisionCheckpointRow> {
  final Value<int> id;
  final Value<String> kind;
  final Value<int> commitId;
  final Value<String> projectionJson;
  final Value<String> assetHashesJson;
  final Value<String> checksum;
  final Value<String> createdAt;
  const RevisionCheckpointsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.commitId = const Value.absent(),
    this.projectionJson = const Value.absent(),
    this.assetHashesJson = const Value.absent(),
    this.checksum = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  RevisionCheckpointsCompanion.insert({
    this.id = const Value.absent(),
    required String kind,
    required int commitId,
    required String projectionJson,
    required String assetHashesJson,
    required String checksum,
    required String createdAt,
  }) : kind = Value(kind),
       commitId = Value(commitId),
       projectionJson = Value(projectionJson),
       assetHashesJson = Value(assetHashesJson),
       checksum = Value(checksum),
       createdAt = Value(createdAt);
  static Insertable<RevisionCheckpointRow> custom({
    Expression<int>? id,
    Expression<String>? kind,
    Expression<int>? commitId,
    Expression<String>? projectionJson,
    Expression<String>? assetHashesJson,
    Expression<String>? checksum,
    Expression<String>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (commitId != null) 'commit_id': commitId,
      if (projectionJson != null) 'projection_json': projectionJson,
      if (assetHashesJson != null) 'asset_hashes_json': assetHashesJson,
      if (checksum != null) 'checksum': checksum,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  RevisionCheckpointsCompanion copyWith({
    Value<int>? id,
    Value<String>? kind,
    Value<int>? commitId,
    Value<String>? projectionJson,
    Value<String>? assetHashesJson,
    Value<String>? checksum,
    Value<String>? createdAt,
  }) {
    return RevisionCheckpointsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      commitId: commitId ?? this.commitId,
      projectionJson: projectionJson ?? this.projectionJson,
      assetHashesJson: assetHashesJson ?? this.assetHashesJson,
      checksum: checksum ?? this.checksum,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (commitId.present) {
      map['commit_id'] = Variable<int>(commitId.value);
    }
    if (projectionJson.present) {
      map['projection_json'] = Variable<String>(projectionJson.value);
    }
    if (assetHashesJson.present) {
      map['asset_hashes_json'] = Variable<String>(assetHashesJson.value);
    }
    if (checksum.present) {
      map['checksum'] = Variable<String>(checksum.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionCheckpointsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('commitId: $commitId, ')
          ..write('projectionJson: $projectionJson, ')
          ..write('assetHashesJson: $assetHashesJson, ')
          ..write('checksum: $checksum, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $RevisionContextsTable extends RevisionContexts
    with TableInfo<$RevisionContextsTable, RevisionContextRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionContextsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    check: () => id.equals(1),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _activeCommitMeta = const VerificationMeta(
    'activeCommit',
  );
  @override
  late final GeneratedColumn<int> activeCommit = GeneratedColumn<int>(
    'active_commit',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _suppressMeta = const VerificationMeta(
    'suppress',
  );
  @override
  late final GeneratedColumn<bool> suppress = GeneratedColumn<bool>(
    'suppress',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("suppress" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [id, activeCommit, suppress];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_context';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionContextRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('active_commit')) {
      context.handle(
        _activeCommitMeta,
        activeCommit.isAcceptableOrUnknown(
          data['active_commit']!,
          _activeCommitMeta,
        ),
      );
    }
    if (data.containsKey('suppress')) {
      context.handle(
        _suppressMeta,
        suppress.isAcceptableOrUnknown(data['suppress']!, _suppressMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RevisionContextRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionContextRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      activeCommit: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}active_commit'],
      ),
      suppress: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}suppress'],
      )!,
    );
  }

  @override
  $RevisionContextsTable createAlias(String alias) {
    return $RevisionContextsTable(attachedDatabase, alias);
  }
}

class RevisionContextRow extends DataClass
    implements Insertable<RevisionContextRow> {
  final int id;
  final int? activeCommit;
  final bool suppress;
  const RevisionContextRow({
    required this.id,
    this.activeCommit,
    required this.suppress,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || activeCommit != null) {
      map['active_commit'] = Variable<int>(activeCommit);
    }
    map['suppress'] = Variable<bool>(suppress);
    return map;
  }

  RevisionContextsCompanion toCompanion(bool nullToAbsent) {
    return RevisionContextsCompanion(
      id: Value(id),
      activeCommit: activeCommit == null && nullToAbsent
          ? const Value.absent()
          : Value(activeCommit),
      suppress: Value(suppress),
    );
  }

  factory RevisionContextRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionContextRow(
      id: serializer.fromJson<int>(json['id']),
      activeCommit: serializer.fromJson<int?>(json['activeCommit']),
      suppress: serializer.fromJson<bool>(json['suppress']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'activeCommit': serializer.toJson<int?>(activeCommit),
      'suppress': serializer.toJson<bool>(suppress),
    };
  }

  RevisionContextRow copyWith({
    int? id,
    Value<int?> activeCommit = const Value.absent(),
    bool? suppress,
  }) => RevisionContextRow(
    id: id ?? this.id,
    activeCommit: activeCommit.present ? activeCommit.value : this.activeCommit,
    suppress: suppress ?? this.suppress,
  );
  RevisionContextRow copyWithCompanion(RevisionContextsCompanion data) {
    return RevisionContextRow(
      id: data.id.present ? data.id.value : this.id,
      activeCommit: data.activeCommit.present
          ? data.activeCommit.value
          : this.activeCommit,
      suppress: data.suppress.present ? data.suppress.value : this.suppress,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionContextRow(')
          ..write('id: $id, ')
          ..write('activeCommit: $activeCommit, ')
          ..write('suppress: $suppress')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, activeCommit, suppress);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionContextRow &&
          other.id == this.id &&
          other.activeCommit == this.activeCommit &&
          other.suppress == this.suppress);
}

class RevisionContextsCompanion extends UpdateCompanion<RevisionContextRow> {
  final Value<int> id;
  final Value<int?> activeCommit;
  final Value<bool> suppress;
  const RevisionContextsCompanion({
    this.id = const Value.absent(),
    this.activeCommit = const Value.absent(),
    this.suppress = const Value.absent(),
  });
  RevisionContextsCompanion.insert({
    this.id = const Value.absent(),
    this.activeCommit = const Value.absent(),
    this.suppress = const Value.absent(),
  });
  static Insertable<RevisionContextRow> custom({
    Expression<int>? id,
    Expression<int>? activeCommit,
    Expression<bool>? suppress,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (activeCommit != null) 'active_commit': activeCommit,
      if (suppress != null) 'suppress': suppress,
    });
  }

  RevisionContextsCompanion copyWith({
    Value<int>? id,
    Value<int?>? activeCommit,
    Value<bool>? suppress,
  }) {
    return RevisionContextsCompanion(
      id: id ?? this.id,
      activeCommit: activeCommit ?? this.activeCommit,
      suppress: suppress ?? this.suppress,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (activeCommit.present) {
      map['active_commit'] = Variable<int>(activeCommit.value);
    }
    if (suppress.present) {
      map['suppress'] = Variable<bool>(suppress.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionContextsCompanion(')
          ..write('id: $id, ')
          ..write('activeCommit: $activeCommit, ')
          ..write('suppress: $suppress')
          ..write(')'))
        .toString();
  }
}

class $RevisionSequencesTable extends RevisionSequences
    with TableInfo<$RevisionSequencesTable, RevisionSequenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RevisionSequencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    check: () => id.equals(1),
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextCommitMeta = const VerificationMeta(
    'nextCommit',
  );
  @override
  late final GeneratedColumn<int> nextCommit = GeneratedColumn<int>(
    'next_commit',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, nextCommit];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'revision_sequence';
  @override
  VerificationContext validateIntegrity(
    Insertable<RevisionSequenceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('next_commit')) {
      context.handle(
        _nextCommitMeta,
        nextCommit.isAcceptableOrUnknown(data['next_commit']!, _nextCommitMeta),
      );
    } else if (isInserting) {
      context.missing(_nextCommitMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RevisionSequenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RevisionSequenceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      nextCommit: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_commit'],
      )!,
    );
  }

  @override
  $RevisionSequencesTable createAlias(String alias) {
    return $RevisionSequencesTable(attachedDatabase, alias);
  }
}

class RevisionSequenceRow extends DataClass
    implements Insertable<RevisionSequenceRow> {
  final int id;
  final int nextCommit;
  const RevisionSequenceRow({required this.id, required this.nextCommit});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['next_commit'] = Variable<int>(nextCommit);
    return map;
  }

  RevisionSequencesCompanion toCompanion(bool nullToAbsent) {
    return RevisionSequencesCompanion(
      id: Value(id),
      nextCommit: Value(nextCommit),
    );
  }

  factory RevisionSequenceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RevisionSequenceRow(
      id: serializer.fromJson<int>(json['id']),
      nextCommit: serializer.fromJson<int>(json['nextCommit']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'nextCommit': serializer.toJson<int>(nextCommit),
    };
  }

  RevisionSequenceRow copyWith({int? id, int? nextCommit}) =>
      RevisionSequenceRow(
        id: id ?? this.id,
        nextCommit: nextCommit ?? this.nextCommit,
      );
  RevisionSequenceRow copyWithCompanion(RevisionSequencesCompanion data) {
    return RevisionSequenceRow(
      id: data.id.present ? data.id.value : this.id,
      nextCommit: data.nextCommit.present
          ? data.nextCommit.value
          : this.nextCommit,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RevisionSequenceRow(')
          ..write('id: $id, ')
          ..write('nextCommit: $nextCommit')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, nextCommit);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RevisionSequenceRow &&
          other.id == this.id &&
          other.nextCommit == this.nextCommit);
}

class RevisionSequencesCompanion extends UpdateCompanion<RevisionSequenceRow> {
  final Value<int> id;
  final Value<int> nextCommit;
  const RevisionSequencesCompanion({
    this.id = const Value.absent(),
    this.nextCommit = const Value.absent(),
  });
  RevisionSequencesCompanion.insert({
    this.id = const Value.absent(),
    required int nextCommit,
  }) : nextCommit = Value(nextCommit);
  static Insertable<RevisionSequenceRow> custom({
    Expression<int>? id,
    Expression<int>? nextCommit,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (nextCommit != null) 'next_commit': nextCommit,
    });
  }

  RevisionSequencesCompanion copyWith({
    Value<int>? id,
    Value<int>? nextCommit,
  }) {
    return RevisionSequencesCompanion(
      id: id ?? this.id,
      nextCommit: nextCommit ?? this.nextCommit,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (nextCommit.present) {
      map['next_commit'] = Variable<int>(nextCommit.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RevisionSequencesCompanion(')
          ..write('id: $id, ')
          ..write('nextCommit: $nextCommit')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  late final $TimetableEntriesTable timetableEntries = $TimetableEntriesTable(
    this,
  );
  late final $AppMetaTable appMeta = $AppMetaTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $LearningGoalsTable learningGoals = $LearningGoalsTable(this);
  late final $AssetObjectsTable assetObjects = $AssetObjectsTable(this);
  late final $AssetChunksTable assetChunks = $AssetChunksTable(this);
  late final $MaterialsTable materials = $MaterialsTable(this);
  late final $MaterialPagesTable materialPages = $MaterialPagesTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $StudyPlansTable studyPlans = $StudyPlansTable(this);
  late final $PlanItemsTable planItems = $PlanItemsTable(this);
  late final $ScheduleBlocksTable scheduleBlocks = $ScheduleBlocksTable(this);
  late final $StudySessionsTable studySessions = $StudySessionsTable(this);
  late final $AttemptsTable attempts = $AttemptsTable(this);
  late final $AssessmentsTable assessments = $AssessmentsTable(this);
  late final $MemoriesTable memories = $MemoriesTable(this);
  late final $RevisionCommitsTable revisionCommits = $RevisionCommitsTable(
    this,
  );
  late final $RevisionChangesTable revisionChanges = $RevisionChangesTable(
    this,
  );
  late final $RevisionRefsTable revisionRefs = $RevisionRefsTable(this);
  late final $RevisionCheckpointsTable revisionCheckpoints =
      $RevisionCheckpointsTable(this);
  late final $RevisionContextsTable revisionContexts = $RevisionContextsTable(
    this,
  );
  late final $RevisionSequencesTable revisionSequences =
      $RevisionSequencesTable(this);
  late final Index idxAssetChunkHash = Index(
    'idx_asset_chunk_hash',
    'CREATE INDEX idx_asset_chunk_hash ON asset_chunk (hash, seq)',
  );
  late final Index idxMaterialGoal = Index(
    'idx_material_goal',
    'CREATE INDEX idx_material_goal ON material (goal_id)',
  );
  late final Index idxMaterialPageMaterial = Index(
    'idx_material_page_material',
    'CREATE INDEX idx_material_page_material ON material_page (material_id, page_no)',
  );
  late final Index idxConversationStatus = Index(
    'idx_conversation_status',
    'CREATE INDEX idx_conversation_status ON conversation (status, updated_at)',
  );
  late final Index idxConversationGoal = Index(
    'idx_conversation_goal',
    'CREATE INDEX idx_conversation_goal ON conversation (goal_id)',
  );
  late final Index idxConversationMaterial = Index(
    'idx_conversation_material',
    'CREATE INDEX idx_conversation_material ON conversation (material_id)',
  );
  late final Index idxMessageConversation = Index(
    'idx_message_conversation',
    'CREATE INDEX idx_message_conversation ON message (conversation_id, created_at)',
  );
  late final Index idxStudyPlanMaterial = Index(
    'idx_study_plan_material',
    'CREATE INDEX idx_study_plan_material ON study_plan (material_id, status)',
  );
  late final Index idxPlanItemStatusDue = Index(
    'idx_plan_item_status_due',
    'CREATE INDEX idx_plan_item_status_due ON plan_item (status, due_at)',
  );
  late final Index idxPlanItemGoal = Index(
    'idx_plan_item_goal',
    'CREATE INDEX idx_plan_item_goal ON plan_item (goal_id)',
  );
  late final Index idxPlanItemConversation = Index(
    'idx_plan_item_conversation',
    'CREATE INDEX idx_plan_item_conversation ON plan_item (conversation_id)',
  );
  late final Index idxPlanItemStudySeq = Index(
    'idx_plan_item_study_seq',
    'CREATE UNIQUE INDEX idx_plan_item_study_seq ON plan_item (study_plan_id, seq)',
  );
  late final Index idxScheduleStart = Index(
    'idx_schedule_start',
    'CREATE INDEX idx_schedule_start ON schedule_block (start_at)',
  );
  late final Index idxSchedulePlan = Index(
    'idx_schedule_plan',
    'CREATE INDEX idx_schedule_plan ON schedule_block (plan_item_id)',
  );
  late final Index idxSessionPlan = Index(
    'idx_session_plan',
    'CREATE INDEX idx_session_plan ON study_session (plan_item_id, started_at)',
  );
  late final Index idxSessionConversation = Index(
    'idx_session_conversation',
    'CREATE INDEX idx_session_conversation ON study_session (conversation_id, ended_at)',
  );
  late final Index idxAttemptConversation = Index(
    'idx_attempt_conversation',
    'CREATE INDEX idx_attempt_conversation ON attempt (conversation_id, submitted_at)',
  );
  late final Index idxAttemptSession = Index(
    'idx_attempt_session',
    'CREATE INDEX idx_attempt_session ON attempt (session_id)',
  );
  late final Index idxAttemptRedo = Index(
    'idx_attempt_redo',
    'CREATE INDEX idx_attempt_redo ON attempt (redo_of_attempt_id)',
  );
  late final Index idxAssessmentAttempt = Index(
    'idx_assessment_attempt',
    'CREATE INDEX idx_assessment_attempt ON assessment (attempt_id, kind)',
  );
  late final Index idxMemoryStatus = Index(
    'idx_memory_status',
    'CREATE INDEX idx_memory_status ON memory (status, kind)',
  );
  late final Index idxMemoryValid = Index(
    'idx_memory_valid',
    'CREATE INDEX idx_memory_valid ON memory (valid_until)',
  );
  late final Index idxRevisionRequest = Index(
    'idx_revision_request',
    'CREATE UNIQUE INDEX idx_revision_request ON revision_commit (request_id) WHERE request_id IS NOT NULL',
  );
  late final Index idxRevisionCommitParent = Index(
    'idx_revision_commit_parent',
    'CREATE INDEX idx_revision_commit_parent ON revision_commit (parent_id)',
  );
  late final Index idxRevisionChangeTarget = Index(
    'idx_revision_change_target',
    'CREATE INDEX idx_revision_change_target ON revision_change (table_name, row_key)',
  );
  late final Index idxRevisionChangeCommit = Index(
    'idx_revision_change_commit',
    'CREATE INDEX idx_revision_change_commit ON revision_change (commit_id, seq)',
  );
  late final Index idxRevisionCheckpointCommit = Index(
    'idx_revision_checkpoint_commit',
    'CREATE INDEX idx_revision_checkpoint_commit ON revision_checkpoint (commit_id, id)',
  );
  Future<int> insertTimetableEntry(
    String id,
    int weekday,
    String startTime,
    String endTime,
    String title,
    String? location,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO timetable_entry (id, weekday, start_time, end_time, title, location, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)',
      variables: [
        Variable<String>(id),
        Variable<int>(weekday),
        Variable<String>(startTime),
        Variable<String>(endTime),
        Variable<String>(title),
        Variable<String>(location),
        Variable<String>(stamp),
      ],
      updates: {this.timetableEntries},
    );
  }

  Future<int> deleteTimetableEntry(String entryId) {
    return customUpdate(
      'DELETE FROM timetable_entry WHERE id = ?1',
      variables: [Variable<String>(entryId)],
      updates: {this.timetableEntries},
      updateKind: UpdateKind.delete,
    );
  }

  Selectable<TimetableEntryRow> allTimetableEntries() {
    return customSelect(
      'SELECT * FROM timetable_entry ORDER BY weekday, start_time',
      variables: [],
      readsFrom: {this.timetableEntries},
    ).asyncMap(this.timetableEntries.mapFromRow);
  }

  Selectable<TimetableEntriesOnWeekdayResult> timetableEntriesOnWeekday(
    int weekday,
  ) {
    return customSelect(
      'SELECT start_time, end_time, title, location FROM timetable_entry WHERE weekday = ?1 ORDER BY start_time',
      variables: [Variable<int>(weekday)],
      readsFrom: {this.timetableEntries},
    ).map(
      (QueryRow row) => TimetableEntriesOnWeekdayResult(
        startTime: row.read<String>('start_time'),
        endTime: row.read<String>('end_time'),
        title: row.read<String>('title'),
        location: row.readNullable<String>('location'),
      ),
    );
  }

  Selectable<StudySessionRow> openStudySession(
    String? conversationId,
    String? planItemId,
    String? goalId,
  ) {
    return customSelect(
      'SELECT * FROM study_session WHERE ended_at IS NULL AND((?1 IS NOT NULL AND conversation_id = ?1)OR(?1 IS NULL AND conversation_id IS NULL AND((?2 IS NOT NULL AND plan_item_id = ?2)OR(?2 IS NULL AND plan_item_id IS NULL AND((?3 IS NULL AND goal_id IS NULL)OR(?3 IS NOT NULL AND goal_id = ?3))))))ORDER BY id DESC LIMIT 1',
      variables: [
        Variable<String>(conversationId),
        Variable<String>(planItemId),
        Variable<String>(goalId),
      ],
      readsFrom: {this.studySessions},
    ).asyncMap(this.studySessions.mapFromRow);
  }

  Selectable<StudySessionRow> studySessionById(String id) {
    return customSelect(
      'SELECT * FROM study_session WHERE id = ?1',
      variables: [Variable<String>(id)],
      readsFrom: {this.studySessions},
    ).asyncMap(this.studySessions.mapFromRow);
  }

  Selectable<StudySessionRow> recentStudySessions(int rowLimit) {
    return customSelect(
      'SELECT * FROM study_session ORDER BY id DESC LIMIT ?1',
      variables: [Variable<int>(rowLimit)],
      readsFrom: {this.studySessions},
    ).asyncMap(this.studySessions.mapFromRow);
  }

  Selectable<StudySessionRow> endedStudySessionsForGoal(
    String? goalId,
    int? rowLimit,
  ) {
    return customSelect(
      'SELECT * FROM study_session WHERE goal_id = ?1 AND ended_at IS NOT NULL ORDER BY ended_at DESC, id DESC LIMIT COALESCE(?2, -1)',
      variables: [Variable<String>(goalId), Variable<int>(rowLimit)],
      readsFrom: {this.studySessions},
    ).asyncMap(this.studySessions.mapFromRow);
  }

  Selectable<StudySessionRow> endedStudySessionsForPlanItems(
    String planItemIds,
  ) {
    return customSelect(
      'SELECT * FROM study_session WHERE plan_item_id IN (SELECT value FROM json_each(?1)) AND ended_at IS NOT NULL ORDER BY ended_at ASC, id ASC',
      variables: [Variable<String>(planItemIds)],
      readsFrom: {this.studySessions},
    ).asyncMap(this.studySessions.mapFromRow);
  }

  Future<int> insertStudySession(
    String id,
    String? goalId,
    String? itemId,
    String? conversationId,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO study_session (id, goal_id, plan_item_id, conversation_id, started_at, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?5)',
      variables: [
        Variable<String>(id),
        Variable<String>(goalId),
        Variable<String>(itemId),
        Variable<String>(conversationId),
        Variable<String>(stamp),
      ],
      updates: {this.studySessions},
    );
  }

  Future<int> finishStudySession(
    String? outcome,
    String? summary,
    String? stamp,
    String sessionId,
  ) {
    return customUpdate(
      'UPDATE study_session SET outcome = ?1, summary = ?2, ended_at = ?3, updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(outcome),
        Variable<String>(summary),
        Variable<String>(stamp),
        Variable<String>(sessionId),
      ],
      updates: {this.studySessions},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> deleteStudySession(String sessionId) {
    return customUpdate(
      'DELETE FROM study_session WHERE id = ?1',
      variables: [Variable<String>(sessionId)],
      updates: {this.studySessions},
      updateKind: UpdateKind.delete,
    );
  }

  Selectable<StudyPlanRow> studyPlanById(String id) {
    return customSelect(
      'SELECT * FROM study_plan WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(id)],
      readsFrom: {this.studyPlans},
    ).asyncMap(this.studyPlans.mapFromRow);
  }

  Selectable<PlanRowsResult> planRows(
    String doneStatus,
    String? id,
    int openOnly,
    String activeStatus,
    String pausedStatus,
    int activeOnly,
    int statusFirst,
    int? rowLimit,
  ) {
    return customSelect(
      'SELECT sp.*, (SELECT title FROM material WHERE id = sp.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = sp.material_id) AS source_file_name, (SELECT COUNT(*) FROM plan_item AS pi WHERE pi.study_plan_id = sp.id AND pi.status = ?1) AS steps_done, (SELECT COUNT(*) FROM plan_item AS pi WHERE pi.study_plan_id = sp.id) AS steps_total, (SELECT pi.title FROM plan_item AS pi WHERE pi.study_plan_id = sp.id AND pi.status IN (\'doing\', \'todo\') ORDER BY CASE pi.status WHEN \'doing\' THEN 0 ELSE 1 END, pi.seq, pi.id LIMIT 1) AS next_step_title FROM study_plan AS sp WHERE(?2 IS NULL OR sp.id = ?2)AND(?3 = 0 OR sp.status IN (?4, ?5))AND(?6 = 0 OR sp.status = ?4)ORDER BY CASE WHEN ?7 = 0 THEN 0 WHEN sp.status = ?4 THEN 0 WHEN sp.status = ?5 THEN 1 ELSE 2 END, sp.updated_at DESC, sp.id DESC LIMIT COALESCE(?8, -1)',
      variables: [
        Variable<String>(doneStatus),
        Variable<String>(id),
        Variable<int>(openOnly),
        Variable<String>(activeStatus),
        Variable<String>(pausedStatus),
        Variable<int>(activeOnly),
        Variable<int>(statusFirst),
        Variable<int>(rowLimit),
      ],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => PlanRowsResult(
        id: row.read<String>('id'),
        materialId: row.readNullable<String>('material_id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        title: row.read<String>('title'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        currentPage: row.readNullable<int>('current_page'),
        status: row.read<String>('status'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        stepsDone: row.read<int>('steps_done'),
        stepsTotal: row.read<int>('steps_total'),
        nextStepTitle: row.readNullable<String>('next_step_title'),
      ),
    );
  }

  Future<int> insertStudyPlan(
    String id,
    String? materialId,
    String? goalId,
    String? conversationId,
    String title,
    int? pageFrom,
    int? pageTo,
    int? currentPage,
    String status,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO study_plan (id, material_id, goal_id, conversation_id, title, page_from, page_to, current_page, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)',
      variables: [
        Variable<String>(id),
        Variable<String>(materialId),
        Variable<String>(goalId),
        Variable<String>(conversationId),
        Variable<String>(title),
        Variable<int>(pageFrom),
        Variable<int>(pageTo),
        Variable<int>(currentPage),
        Variable<String>(status),
        Variable<String>(stamp),
      ],
      updates: {this.studyPlans},
    );
  }

  Future<int> setStudyPlanStatus(String status, String stamp, String planId) {
    return customUpdate(
      'UPDATE study_plan SET status = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(status),
        Variable<String>(stamp),
        Variable<String>(planId),
      ],
      updates: {this.studyPlans},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> updateStudyPlanProgress(
    int? currentPage,
    String? status,
    String stamp,
    String planId,
  ) {
    return customUpdate(
      'UPDATE study_plan SET current_page = ?1, status = COALESCE(?2, status), updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<int>(currentPage),
        Variable<String>(status),
        Variable<String>(stamp),
        Variable<String>(planId),
      ],
      updates: {this.studyPlans},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<int> cutoffHour() {
    return customSelect(
      'SELECT day_cutoff_hour FROM profile WHERE id = 1',
      variables: [],
      readsFrom: {this.profiles},
    ).map((QueryRow row) => row.read<int>('day_cutoff_hour'));
  }

  Selectable<String> appMetaValue(String metaKey) {
    return customSelect(
      'SELECT a.value AS meta_value FROM app_meta AS a WHERE a."key" = ?1 LIMIT 1',
      variables: [Variable<String>(metaKey)],
      readsFrom: {this.appMeta},
    ).map((QueryRow row) => row.read<String>('meta_value'));
  }

  Future<int> setProfileCutoffHour(int hour, String stamp) {
    return customUpdate(
      'UPDATE profile SET day_cutoff_hour = ?1, updated_at = ?2 WHERE id = 1',
      variables: [Variable<int>(hour), Variable<String>(stamp)],
      updates: {this.profiles},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> saveAppMetadata(String metaKey, String metaValue, String stamp) {
    return customInsert(
      'INSERT INTO app_meta ("key", value, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT ("key") DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
      variables: [
        Variable<String>(metaKey),
        Variable<String>(metaValue),
        Variable<String>(stamp),
      ],
      updates: {this.appMeta},
    );
  }

  Selectable<BlocksOverlappingResult> blocksOverlapping(
    String endAt,
    String startAt,
  ) {
    return customSelect(
      'SELECT b.*, p.title AS p_title, p.note AS p_note, p.status AS p_status FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE b.start_at < ?1 AND b.end_at > ?2 ORDER BY b.start_at',
      variables: [Variable<String>(endAt), Variable<String>(startAt)],
      readsFrom: {this.planItems, this.scheduleBlocks},
    ).map(
      (QueryRow row) => BlocksOverlappingResult(
        id: row.read<String>('id'),
        planItemId: row.read<String>('plan_item_id'),
        startAt: row.read<String>('start_at'),
        endAt: row.read<String>('end_at'),
        source: row.read<String>('source'),
        status: row.read<String>('status'),
        locked: row.read<bool>('locked'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        pTitle: row.read<String>('p_title'),
        pNote: row.readNullable<String>('p_note'),
        pStatus: row.read<String>('p_status'),
      ),
    );
  }

  Selectable<NextPlannedBlockResult> nextPlannedBlock(String now) {
    return customSelect(
      'SELECT b.*, p.title AS p_title, p.note AS p_note, p.status AS p_status FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE b.status = \'planned\' AND b.start_at >= ?1 ORDER BY b.start_at LIMIT 1',
      variables: [Variable<String>(now)],
      readsFrom: {this.planItems, this.scheduleBlocks},
    ).map(
      (QueryRow row) => NextPlannedBlockResult(
        id: row.read<String>('id'),
        planItemId: row.read<String>('plan_item_id'),
        startAt: row.read<String>('start_at'),
        endAt: row.read<String>('end_at'),
        source: row.read<String>('source'),
        status: row.read<String>('status'),
        locked: row.read<bool>('locked'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        pTitle: row.read<String>('p_title'),
        pNote: row.readNullable<String>('p_note'),
        pStatus: row.read<String>('p_status'),
      ),
    );
  }

  Selectable<PlannedBlockSpansResult> plannedBlockSpans() {
    return customSelect(
      'SELECT b.id, b.start_at, b.end_at, p.title FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE b.status = \'planned\' ORDER BY b.start_at',
      variables: [],
      readsFrom: {this.scheduleBlocks, this.planItems},
    ).map(
      (QueryRow row) => PlannedBlockSpansResult(
        id: row.read<String>('id'),
        startAt: row.read<String>('start_at'),
        endAt: row.read<String>('end_at'),
        title: row.read<String>('title'),
      ),
    );
  }

  Selectable<ScheduleBlockRow> adjustableBlocksForGoal(
    String? goalId,
    String now,
  ) {
    return customSelect(
      'SELECT b.* FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE p.goal_id = ?1 AND b.status = \'planned\' AND b.locked = 0 AND b.start_at >= ?2 ORDER BY b.start_at',
      variables: [Variable<String>(goalId), Variable<String>(now)],
      readsFrom: {this.scheduleBlocks, this.planItems},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> blocksByIds(String ids) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE id IN (SELECT value FROM json_each(?1))',
      variables: [Variable<String>(ids)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> upcomingBlocksForItem(
    String planItemId,
    String now,
  ) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE plan_item_id = ?1 AND status = \'planned\' AND start_at >= ?2 ORDER BY start_at',
      variables: [Variable<String>(planItemId), Variable<String>(now)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> firstLiveBlockPerItem(
    String planItemIds,
    String now,
  ) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE plan_item_id IN (SELECT value FROM json_each(?1)) AND status = \'planned\' AND end_at > ?2 ORDER BY start_at, id',
      variables: [Variable<String>(planItemIds), Variable<String>(now)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> upcomingBlocksForItems(
    String planItemIds,
    String now,
  ) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE plan_item_id IN (SELECT value FROM json_each(?1)) AND status = \'planned\' AND start_at >= ?2 ORDER BY start_at',
      variables: [Variable<String>(planItemIds), Variable<String>(now)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> scheduleBlockById(String id) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(id)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Selectable<ScheduleBlockRow> blocksForItem(String planItemId) {
    return customSelect(
      'SELECT * FROM schedule_block WHERE plan_item_id = ?1 ORDER BY start_at',
      variables: [Variable<String>(planItemId)],
      readsFrom: {this.scheduleBlocks},
    ).asyncMap(this.scheduleBlocks.mapFromRow);
  }

  Future<int> cancelPlannedBlocksForItem(String stamp, String itemId) {
    return customUpdate(
      'UPDATE schedule_block SET status = \'cancelled\', updated_at = ?1 WHERE plan_item_id = ?2 AND status = \'planned\'',
      variables: [Variable<String>(stamp), Variable<String>(itemId)],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> insertScheduleBlock(
    String id,
    String itemId,
    String startAt,
    String endAt,
    String source,
    bool locked,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO schedule_block (id, plan_item_id, start_at, end_at, source, status, locked, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, \'planned\', ?6, ?7, ?7)',
      variables: [
        Variable<String>(id),
        Variable<String>(itemId),
        Variable<String>(startAt),
        Variable<String>(endAt),
        Variable<String>(source),
        Variable<bool>(locked),
        Variable<String>(stamp),
      ],
      updates: {this.scheduleBlocks},
    );
  }

  Future<int> updatePlannedBlockTime(
    String startAt,
    String endAt,
    String stamp,
    String blockId,
  ) {
    return customUpdate(
      'UPDATE schedule_block SET start_at = ?1, end_at = ?2, status = \'planned\', updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(startAt),
        Variable<String>(endAt),
        Variable<String>(stamp),
        Variable<String>(blockId),
      ],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setBlockLocked(bool locked, String stamp, String blockId) {
    return customUpdate(
      'UPDATE schedule_block SET locked = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<bool>(locked),
        Variable<String>(stamp),
        Variable<String>(blockId),
      ],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> cancelPlannedBlocks(String stamp, String ids) {
    return customUpdate(
      'UPDATE schedule_block SET status = \'cancelled\', updated_at = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND status = \'planned\'',
      variables: [Variable<String>(stamp), Variable<String>(ids)],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setScheduleBlockStatus(
    String status,
    String stamp,
    String blockId,
  ) {
    return customUpdate(
      'UPDATE schedule_block SET status = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(status),
        Variable<String>(stamp),
        Variable<String>(blockId),
      ],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> deleteScheduleBlock(String blockId) {
    return customUpdate(
      'DELETE FROM schedule_block WHERE id = ?1',
      variables: [Variable<String>(blockId)],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.delete,
    );
  }

  Selectable<FindOverlappingBlocksResult> findOverlappingBlocks(
    String endAt,
    String startAt,
    String ignoredBlockIds,
  ) {
    return customSelect(
      'SELECT b.start_at, b.end_at, p.title FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE b.status = \'planned\' AND b.start_at < ?1 AND b.end_at > ?2 AND b.id NOT IN (SELECT value FROM json_each(?3)) ORDER BY b.start_at LIMIT 1',
      variables: [
        Variable<String>(endAt),
        Variable<String>(startAt),
        Variable<String>(ignoredBlockIds),
      ],
      readsFrom: {this.scheduleBlocks, this.planItems},
    ).map(
      (QueryRow row) => FindOverlappingBlocksResult(
        startAt: row.read<String>('start_at'),
        endAt: row.read<String>('end_at'),
        title: row.read<String>('title'),
      ),
    );
  }

  Selectable<PlannedBlocksAfterResult> plannedBlocksAfter(String after) {
    return customSelect(
      'SELECT b.start_at, b.end_at, p.title FROM schedule_block AS b JOIN plan_item AS p ON p.id = b.plan_item_id WHERE b.status = \'planned\' AND b.end_at > ?1 ORDER BY b.start_at',
      variables: [Variable<String>(after)],
      readsFrom: {this.scheduleBlocks, this.planItems},
    ).map(
      (QueryRow row) => PlannedBlocksAfterResult(
        startAt: row.read<String>('start_at'),
        endAt: row.read<String>('end_at'),
        title: row.read<String>('title'),
      ),
    );
  }

  Selectable<ItemByConversationAndTitleResult> itemByConversationAndTitle(
    String? conversationId,
    String title,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.conversation_id = ?1 AND p.title = ?2 ORDER BY p.id DESC LIMIT 1',
      variables: [Variable<String>(conversationId), Variable<String>(title)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => ItemByConversationAndTitleResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<ItemPlanResult> itemPlan(String itemId) {
    return customSelect(
      'SELECT id, study_plan_id FROM plan_item WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(itemId)],
      readsFrom: {this.planItems},
    ).map(
      (QueryRow row) => ItemPlanResult(
        id: row.read<String>('id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
      ),
    );
  }

  Selectable<PlanItemRow> stepsOfPlan(String? planId) {
    return customSelect(
      'SELECT * FROM plan_item WHERE study_plan_id = ?1 ORDER BY seq, id',
      variables: [Variable<String>(planId)],
      readsFrom: {this.planItems},
    ).asyncMap(this.planItems.mapFromRow);
  }

  Future<int> insertStudyPlanStep(
    String id,
    String? goalId,
    String? planId,
    int? seq,
    String title,
    String? note,
    int? pageFrom,
    int? pageTo,
    String status,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO plan_item (id, goal_id, conversation_id, study_plan_id, seq, title, note, page_from, page_to, priority, status, source, created_at, updated_at) VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, \'user\', ?10, ?10)',
      variables: [
        Variable<String>(id),
        Variable<String>(goalId),
        Variable<String>(planId),
        Variable<int>(seq),
        Variable<String>(title),
        Variable<String>(note),
        Variable<int>(pageFrom),
        Variable<int>(pageTo),
        Variable<String>(status),
        Variable<String>(stamp),
      ],
      updates: {this.planItems},
    );
  }

  Future<int> setStudyStepConversation(
    String? conversationId,
    String stepId,
    String? planId,
  ) {
    return customUpdate(
      'UPDATE plan_item SET conversation_id = ?1 WHERE id = ?2 AND study_plan_id = ?3',
      variables: [
        Variable<String>(conversationId),
        Variable<String>(stepId),
        Variable<String>(planId),
      ],
      updates: {this.planItems},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setStudyStepStatus(
    String status,
    String? completedAt,
    String stamp,
    String itemId,
  ) {
    return customUpdate(
      'UPDATE plan_item SET status = ?1, completed_at = ?2, updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(status),
        Variable<String>(completedAt),
        Variable<String>(stamp),
        Variable<String>(itemId),
      ],
      updates: {this.planItems},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> resetOtherActiveStudySteps(
    String todoStatus,
    String stamp,
    String? planId,
    String itemId,
    String doingStatus,
  ) {
    return customUpdate(
      'UPDATE plan_item SET status = ?1, updated_at = ?2 WHERE study_plan_id = ?3 AND id != ?4 AND status = ?5',
      variables: [
        Variable<String>(todoStatus),
        Variable<String>(stamp),
        Variable<String>(planId),
        Variable<String>(itemId),
        Variable<String>(doingStatus),
      ],
      updates: {this.planItems},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<PlanStepsResult> planSteps(String? planId) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.study_plan_id = ?1 ORDER BY p.seq, p.id',
      variables: [Variable<String>(planId)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => PlanStepsResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<PlanStepsForPlansResult> planStepsForPlans(String planIds) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.study_plan_id IN (SELECT value FROM json_each(?1)) ORDER BY p.study_plan_id, p.seq, p.id',
      variables: [Variable<String>(planIds)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => PlanStepsForPlansResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Future<int> settleBlocksOnStepDone(
    String now,
    String doneStatus,
    String cancelledStatus,
    String itemId,
    String plannedStatus,
  ) {
    return customUpdate(
      'UPDATE schedule_block SET status = CASE WHEN EXISTS (SELECT 1 FROM study_session AS s WHERE s.plan_item_id = schedule_block.plan_item_id AND s.started_at < schedule_block.end_at AND COALESCE(s.ended_at, ?1) > schedule_block.start_at) THEN ?2 ELSE ?3 END, updated_at = ?1 WHERE plan_item_id = ?4 AND status = ?5',
      variables: [
        Variable<String>(now),
        Variable<String>(doneStatus),
        Variable<String>(cancelledStatus),
        Variable<String>(itemId),
        Variable<String>(plannedStatus),
      ],
      updates: {this.scheduleBlocks},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<ItemsResult> items(
    int openOnly,
    String todoStatus,
    String doingStatus,
    int onlyActiveGoals,
    String? activeStatus,
    int statusFirst,
    String deferredStatus,
    String doneStatus,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p LEFT JOIN learning_goal AS g ON g.id = p.goal_id WHERE(?1 = 0 OR p.status IN (?2, ?3))AND(?4 = 0 OR p.goal_id IS NULL OR g.status = ?5)ORDER BY CASE WHEN ?6 = 0 THEN 0 WHEN p.status = ?3 THEN 0 WHEN p.status = ?2 THEN 1 WHEN p.status = ?7 THEN 2 WHEN p.status = ?8 THEN 3 ELSE 4 END, p.due_at IS NULL, p.due_at, p.id DESC',
      variables: [
        Variable<int>(openOnly),
        Variable<String>(todoStatus),
        Variable<String>(doingStatus),
        Variable<int>(onlyActiveGoals),
        Variable<String>(activeStatus),
        Variable<int>(statusFirst),
        Variable<String>(deferredStatus),
        Variable<String>(doneStatus),
      ],
      readsFrom: {
        this.materials,
        this.studyPlans,
        this.planItems,
        this.learningGoals,
      },
    ).map(
      (QueryRow row) => ItemsResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<ItemByIdResult> itemById(String id) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.id = ?1',
      variables: [Variable<String>(id)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => ItemByIdResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<ItemByConversationResult> itemByConversation(
    String? conversationId,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.conversation_id = ?1 ORDER BY p.id DESC LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => ItemByConversationResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<ItemByConversationAndStepResult> itemByConversationAndStep(
    String? conversationId,
    String stepId,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.conversation_id = ?1 AND json_extract(p.origin_json, \'\$.step_id\') = ?2 ORDER BY p.id DESC LIMIT 1',
      variables: [Variable<String>(conversationId), Variable<String>(stepId)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => ItemByConversationAndStepResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<DoneItemsResult> doneItems(
    String doneStatus,
    int rowLimit,
    int rowOffset,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.status = ?1 ORDER BY p.completed_at DESC, p.id DESC LIMIT ?2 OFFSET ?3',
      variables: [
        Variable<String>(doneStatus),
        Variable<int>(rowLimit),
        Variable<int>(rowOffset),
      ],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => DoneItemsResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<int> countDoneItems(String doneStatus) {
    return customSelect(
      'SELECT COUNT(*) AS n FROM plan_item WHERE status = ?1',
      variables: [Variable<String>(doneStatus)],
      readsFrom: {this.planItems},
    ).map((QueryRow row) => row.read<int>('n'));
  }

  Selectable<ItemsByIdsResult> itemsByIds(String itemIds) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p WHERE p.id IN (SELECT value FROM json_each(?1))',
      variables: [Variable<String>(itemIds)],
      readsFrom: {this.materials, this.studyPlans, this.planItems},
    ).map(
      (QueryRow row) => ItemsByIdsResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<NextDueItemResult> nextDueItem(
    String todoStatus,
    String doingStatus,
    String? activeStatus,
  ) {
    return customSelect(
      'SELECT p.*, (SELECT m.source_file_name FROM study_plan AS sp JOIN material AS m ON m.id = sp.material_id WHERE sp.id = p.study_plan_id) AS source_file_name FROM plan_item AS p LEFT JOIN learning_goal AS g ON g.id = p.goal_id WHERE p.status IN (?1, ?2) AND(p.goal_id IS NULL OR g.status = ?3)ORDER BY p.due_at IS NULL, p.due_at, p.id LIMIT 1',
      variables: [
        Variable<String>(todoStatus),
        Variable<String>(doingStatus),
        Variable<String>(activeStatus),
      ],
      readsFrom: {
        this.materials,
        this.studyPlans,
        this.planItems,
        this.learningGoals,
      },
    ).map(
      (QueryRow row) => NextDueItemResult(
        id: row.read<String>('id'),
        goalId: row.readNullable<String>('goal_id'),
        conversationId: row.readNullable<String>('conversation_id'),
        studyPlanId: row.readNullable<String>('study_plan_id'),
        seq: row.readNullable<int>('seq'),
        title: row.read<String>('title'),
        note: row.readNullable<String>('note'),
        pageFrom: row.readNullable<int>('page_from'),
        pageTo: row.readNullable<int>('page_to'),
        dueAt: row.readNullable<String>('due_at'),
        estMinutes: row.readNullable<int>('est_minutes'),
        priority: row.read<int>('priority'),
        status: row.read<String>('status'),
        source: row.read<String>('source'),
        originJson: row.readNullable<String>('origin_json'),
        completedAt: row.readNullable<String>('completed_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Future<int> bindTaskConversation(
    String? conversationId,
    String stamp,
    String itemId,
  ) {
    return customUpdate(
      'UPDATE plan_item SET conversation_id = ?1, updated_at = ?2 WHERE id = ?3 AND conversation_id IS NULL',
      variables: [
        Variable<String>(conversationId),
        Variable<String>(stamp),
        Variable<String>(itemId),
      ],
      updates: {this.planItems},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> insertPlanItem(
    String id,
    String? goalId,
    String? conversationId,
    String title,
    String? note,
    String? dueAt,
    int? estMinutes,
    String status,
    String source,
    String? origin,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO plan_item (id, goal_id, conversation_id, title, note, due_at, est_minutes, status, source, origin_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)',
      variables: [
        Variable<String>(id),
        Variable<String>(goalId),
        Variable<String>(conversationId),
        Variable<String>(title),
        Variable<String>(note),
        Variable<String>(dueAt),
        Variable<int>(estMinutes),
        Variable<String>(status),
        Variable<String>(source),
        Variable<String>(origin),
        Variable<String>(stamp),
      ],
      updates: {this.planItems},
    );
  }

  Future<int> setPlanItemPriority(int priority, String stamp, String itemId) {
    return customUpdate(
      'UPDATE plan_item SET priority = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<int>(priority),
        Variable<String>(stamp),
        Variable<String>(itemId),
      ],
      updates: {this.planItems},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<MessageRow> recentMessages(String conversationId, int? rowLimit) {
    return customSelect(
      'SELECT * FROM message WHERE conversation_id = ?1 ORDER BY id DESC LIMIT COALESCE(?2, -1)',
      variables: [Variable<String>(conversationId), Variable<int>(rowLimit)],
      readsFrom: {this.messages},
    ).asyncMap(this.messages.mapFromRow);
  }

  Selectable<MessageRow> messagesPage(
    String conversationId,
    String? beforeId,
    int rowLimit,
  ) {
    return customSelect(
      'SELECT * FROM message WHERE conversation_id = ?1 AND(?2 IS NULL OR id < ?2)ORDER BY id DESC LIMIT ?3',
      variables: [
        Variable<String>(conversationId),
        Variable<String>(beforeId),
        Variable<int>(rowLimit),
      ],
      readsFrom: {this.messages},
    ).asyncMap(this.messages.mapFromRow);
  }

  Selectable<MessageRow> firstUserMessage(
    String conversationId,
    String? beforeId,
  ) {
    return customSelect(
      'SELECT * FROM message WHERE conversation_id = ?1 AND role = \'user\' AND(TRIM(content) <> \'\' OR image_paths_json IS NOT NULL)AND(?2 IS NULL OR id < ?2)ORDER BY id LIMIT 1',
      variables: [Variable<String>(conversationId), Variable<String>(beforeId)],
      readsFrom: {this.messages},
    ).asyncMap(this.messages.mapFromRow);
  }

  Selectable<MessageRow> lastUserMessage(String conversationId) {
    return customSelect(
      'SELECT * FROM message WHERE conversation_id = ?1 AND role = \'user\' AND(TRIM(content) <> \'\' OR image_paths_json IS NOT NULL)ORDER BY id DESC LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.messages},
    ).asyncMap(this.messages.mapFromRow);
  }

  Selectable<MessageRow> messageById(String id) {
    return customSelect(
      'SELECT * FROM message WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(id)],
      readsFrom: {this.messages},
    ).asyncMap(this.messages.mapFromRow);
  }

  Selectable<String?> imagePathsOfConversation(String conversationId) {
    return customSelect(
      'SELECT image_paths_json FROM message WHERE conversation_id = ?1 AND image_paths_json IS NOT NULL',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.messages},
    ).map((QueryRow row) => row.readNullable<String>('image_paths_json'));
  }

  Future<int> insertConversationMessage(
    String id,
    String conversationId,
    String role,
    String content,
    String? imagePaths,
    String? structuredJson,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO message (id, conversation_id, role, content, image_paths_json, structured_json, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)',
      variables: [
        Variable<String>(id),
        Variable<String>(conversationId),
        Variable<String>(role),
        Variable<String>(content),
        Variable<String>(imagePaths),
        Variable<String>(structuredJson),
        Variable<String>(stamp),
      ],
      updates: {this.messages},
    );
  }

  Future<int> deleteConversationMessages(String conversationId) {
    return customUpdate(
      'DELETE FROM message WHERE conversation_id = ?1',
      variables: [Variable<String>(conversationId)],
      updates: {this.messages},
      updateKind: UpdateKind.delete,
    );
  }

  Future<int> setMessageStructuredState(
    String? structuredJson,
    String messageId,
  ) {
    return customUpdate(
      'UPDATE message SET structured_json = ?1 WHERE id = ?2',
      variables: [
        Variable<String>(structuredJson),
        Variable<String>(messageId),
      ],
      updates: {this.messages},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<EvidenceMessageCurrentResult> evidenceMessageCurrent(
    String messageId,
  ) {
    return customSelect(
      'SELECT m.content, m.created_at, c.id AS conversation_id, c.title, c.goal_id, c.material_id FROM message AS m JOIN conversation AS c ON c.id = m.conversation_id WHERE m.id = ?1 LIMIT 1',
      variables: [Variable<String>(messageId)],
      readsFrom: {this.messages, this.conversations},
    ).map(
      (QueryRow row) => EvidenceMessageCurrentResult(
        content: row.read<String>('content'),
        createdAt: row.read<String>('created_at'),
        conversationId: row.read<String>('conversation_id'),
        title: row.readNullable<String>('title'),
        goalId: row.readNullable<String>('goal_id'),
        materialId: row.readNullable<String>('material_id'),
      ),
    );
  }

  Selectable<EvidenceMessageSourcesResult> evidenceMessageSources() {
    return customSelect(
      'SELECT m.id, m.conversation_id, m.content, m.created_at, c.material_id FROM message AS m JOIN conversation AS c ON c.id = m.conversation_id WHERE m.role IN (\'user\', \'assistant\') AND m.content != \'\' ORDER BY m.id DESC',
      variables: [],
      readsFrom: {this.messages, this.conversations},
    ).map(
      (QueryRow row) => EvidenceMessageSourcesResult(
        id: row.read<String>('id'),
        conversationId: row.read<String>('conversation_id'),
        content: row.read<String>('content'),
        createdAt: row.read<String>('created_at'),
        materialId: row.readNullable<String>('material_id'),
      ),
    );
  }

  Selectable<EvidenceMessageSourceResult> evidenceMessageSource(
    String messageId,
  ) {
    return customSelect(
      'SELECT content, created_at FROM message WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(messageId)],
      readsFrom: {this.messages},
    ).map(
      (QueryRow row) => EvidenceMessageSourceResult(
        content: row.read<String>('content'),
        createdAt: row.read<String>('created_at'),
      ),
    );
  }

  Selectable<MemoryRow> listMemories(int activeOnly) {
    return customSelect(
      'SELECT * FROM memory WHERE(?1 = 0 OR status = \'active\')ORDER BY status, updated_at DESC, id DESC',
      variables: [Variable<int>(activeOnly)],
      readsFrom: {this.memories},
    ).asyncMap(this.memories.mapFromRow);
  }

  Selectable<ActiveDifficultiesResult> activeDifficulties(
    String kind,
    String scope,
  ) {
    return customSelect(
      'SELECT id, content FROM memory WHERE status = \'active\' AND kind = ?1 AND((?2 = \'\' AND scope IS NULL)OR(?2 <> \'\' AND scope = ?2))ORDER BY id DESC',
      variables: [Variable<String>(kind), Variable<String>(scope)],
      readsFrom: {this.memories},
    ).map(
      (QueryRow row) => ActiveDifficultiesResult(
        id: row.read<String>('id'),
        content: row.read<String>('content'),
      ),
    );
  }

  Selectable<MemoryRow> memoryById(String id) {
    return customSelect(
      'SELECT * FROM memory WHERE id = ?1',
      variables: [Variable<String>(id)],
      readsFrom: {this.memories},
    ).asyncMap(this.memories.mapFromRow);
  }

  Selectable<ActiveMemoryIdentitiesResult> activeMemoryIdentities(String? now) {
    return customSelect(
      'SELECT kind, scope, content FROM memory WHERE status = \'active\' AND(valid_until IS NULL OR valid_until >= ?1)',
      variables: [Variable<String>(now)],
      readsFrom: {this.memories},
    ).map(
      (QueryRow row) => ActiveMemoryIdentitiesResult(
        kind: row.read<String>('kind'),
        scope: row.readNullable<String>('scope'),
        content: row.read<String>('content'),
      ),
    );
  }

  Selectable<MemoryRow> memoriesForContext(
    String? now,
    String scope,
    int? rowLimit,
  ) {
    return customSelect(
      'SELECT * FROM memory WHERE status = \'active\' AND(valid_until IS NULL OR valid_until >= ?1)AND((?2 = \'\' AND scope IS NULL)OR(?2 <> \'\' AND(scope IS NULL OR scope = ?2)))ORDER BY CASE WHEN scope IS NULL THEN 1 ELSE 0 END, CASE kind WHEN \'constraint\' THEN 0 WHEN \'preference\' THEN 1 WHEN \'difficulty\' THEN 2 ELSE 3 END, updated_at DESC, id DESC LIMIT COALESCE(?3, -1)',
      variables: [
        Variable<String>(now),
        Variable<String>(scope),
        Variable<int>(rowLimit),
      ],
      readsFrom: {this.memories},
    ).asyncMap(this.memories.mapFromRow);
  }

  Selectable<String> hasMemoryFromSource(String sourceKind, String? sourceId) {
    return customSelect(
      'SELECT id FROM memory WHERE source_kind = ?1 AND source_id = ?2 LIMIT 1',
      variables: [Variable<String>(sourceKind), Variable<String>(sourceId)],
      readsFrom: {this.memories},
    ).map((QueryRow row) => row.read<String>('id'));
  }

  Future<int> insertMemory(
    String id,
    String kind,
    String content,
    String? scope,
    String sourceKind,
    String? sourceId,
    String? validUntil,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO memory (id, kind, content, scope, source_kind, source_id, valid_until, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, \'active\', ?8, ?8)',
      variables: [
        Variable<String>(id),
        Variable<String>(kind),
        Variable<String>(content),
        Variable<String>(scope),
        Variable<String>(sourceKind),
        Variable<String>(sourceId),
        Variable<String>(validUntil),
        Variable<String>(stamp),
      ],
      updates: {this.memories},
    );
  }

  Future<int> updateMemoryContent(
    String content,
    String? validUntil,
    String kind,
    String? scope,
    String stamp,
    String memoryId,
  ) {
    return customUpdate(
      'UPDATE memory SET content = ?1, valid_until = ?2, kind = ?3, scope = ?4, updated_at = ?5 WHERE id = ?6',
      variables: [
        Variable<String>(content),
        Variable<String>(validUntil),
        Variable<String>(kind),
        Variable<String>(scope),
        Variable<String>(stamp),
        Variable<String>(memoryId),
      ],
      updates: {this.memories},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setMemoryStatus(String status, String stamp, String memoryId) {
    return customUpdate(
      'UPDATE memory SET status = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(status),
        Variable<String>(stamp),
        Variable<String>(memoryId),
      ],
      updates: {this.memories},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<String?> materialFileHash(String materialId) {
    return customSelect(
      'SELECT source_file_hash FROM material WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(materialId)],
      readsFrom: {this.materials},
    ).map((QueryRow row) => row.readNullable<String>('source_file_hash'));
  }

  Selectable<MaterialByIdResult> materialById(String id) {
    return customSelect(
      'SELECT m.*, (SELECT COUNT(*) FROM material_page AS p WHERE p.material_id = m.id) AS page_count FROM material AS m WHERE m.id = ?1',
      variables: [Variable<String>(id)],
      readsFrom: {this.materialPages, this.materials},
    ).map(
      (QueryRow row) => MaterialByIdResult(
        id: row.read<String>('id'),
        title: row.read<String>('title'),
        kind: row.read<String>('kind'),
        sourceRef: row.readNullable<String>('source_ref'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        sourceFileHash: row.readNullable<String>('source_file_hash'),
        goalId: row.readNullable<String>('goal_id'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        pageCount: row.read<int>('page_count'),
      ),
    );
  }

  Selectable<MaterialListResult> materialList(String? goalId) {
    return customSelect(
      'SELECT m.*, (SELECT COUNT(*) FROM material_page AS p WHERE p.material_id = m.id) AS page_count FROM material AS m WHERE(?1 IS NULL OR m.goal_id = ?1 OR m.goal_id IS NULL)ORDER BY m.updated_at DESC, m.id DESC',
      variables: [Variable<String>(goalId)],
      readsFrom: {this.materialPages, this.materials},
    ).map(
      (QueryRow row) => MaterialListResult(
        id: row.read<String>('id'),
        title: row.read<String>('title'),
        kind: row.read<String>('kind'),
        sourceRef: row.readNullable<String>('source_ref'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        sourceFileHash: row.readNullable<String>('source_file_hash'),
        goalId: row.readNullable<String>('goal_id'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        pageCount: row.read<int>('page_count'),
      ),
    );
  }

  Future<int> insertMaterial(
    String id,
    String title,
    String kind,
    String? sourceRef,
    String? fileName,
    String? fileHash,
    String? goalId,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO material (id, title, kind, source_ref, source_file_name, source_file_hash, goal_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)',
      variables: [
        Variable<String>(id),
        Variable<String>(title),
        Variable<String>(kind),
        Variable<String>(sourceRef),
        Variable<String>(fileName),
        Variable<String>(fileHash),
        Variable<String>(goalId),
        Variable<String>(stamp),
      ],
      updates: {this.materials},
    );
  }

  Future<int> setMaterialGoal(String? goalId, String stamp, String materialId) {
    return customUpdate(
      'UPDATE material SET goal_id = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(goalId),
        Variable<String>(stamp),
        Variable<String>(materialId),
      ],
      updates: {this.materials},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> touchMaterial(String stamp, String materialId) {
    return customUpdate(
      'UPDATE material SET updated_at = ?1 WHERE id = ?2',
      variables: [Variable<String>(stamp), Variable<String>(materialId)],
      updates: {this.materials},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<MaterialPageRow> pagesOfMaterial(String materialId) {
    return customSelect(
      'SELECT * FROM material_page WHERE material_id = ?1 ORDER BY page_no',
      variables: [Variable<String>(materialId)],
      readsFrom: {this.materialPages},
    ).asyncMap(this.materialPages.mapFromRow);
  }

  Selectable<MaterialPageRow> pagesInRange(
    String materialId,
    int? pageFrom,
    int? pageTo,
  ) {
    return customSelect(
      'SELECT * FROM material_page WHERE material_id = ?1 AND(?2 IS NULL OR page_no >= ?2)AND(?3 IS NULL OR page_no <= ?3)ORDER BY page_no',
      variables: [
        Variable<String>(materialId),
        Variable<int>(pageFrom),
        Variable<int>(pageTo),
      ],
      readsFrom: {this.materialPages},
    ).asyncMap(this.materialPages.mapFromRow);
  }

  Selectable<MaterialPageRow> pageById(String pageId) {
    return customSelect(
      'SELECT * FROM material_page WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(pageId)],
      readsFrom: {this.materialPages},
    ).asyncMap(this.materialPages.mapFromRow);
  }

  Selectable<String> pageMaterialId(String pageId) {
    return customSelect(
      'SELECT material_id FROM material_page WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(pageId)],
      readsFrom: {this.materialPages},
    ).map((QueryRow row) => row.read<String>('material_id'));
  }

  Future<int> insertMaterialPage(
    String id,
    String materialId,
    int pageNo,
    String? label,
    String content,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO material_page (id, material_id, page_no, label, content, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)',
      variables: [
        Variable<String>(id),
        Variable<String>(materialId),
        Variable<int>(pageNo),
        Variable<String>(label),
        Variable<String>(content),
        Variable<String>(stamp),
      ],
      updates: {this.materialPages},
    );
  }

  Future<int> updateMaterialPage(
    String content,
    String? label,
    String stamp,
    String pageId,
  ) {
    return customUpdate(
      'UPDATE material_page SET content = ?1, label = ?2, updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(content),
        Variable<String>(label),
        Variable<String>(stamp),
        Variable<String>(pageId),
      ],
      updates: {this.materialPages},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<MaterialPageBoundsResult> materialPageBounds(String materialId) {
    return customSelect(
      'SELECT MIN(page_no) AS first_page, MAX(page_no) AS last_page FROM material_page WHERE material_id = ?1',
      variables: [Variable<String>(materialId)],
      readsFrom: {this.materialPages},
    ).map(
      (QueryRow row) => MaterialPageBoundsResult(
        firstPage: row.readNullable<int>('first_page'),
        lastPage: row.readNullable<int>('last_page'),
      ),
    );
  }

  Selectable<MaterialPageRow> materialPageByNumber(
    String materialId,
    int pageNo,
  ) {
    return customSelect(
      'SELECT * FROM material_page WHERE material_id = ?1 AND page_no = ?2 LIMIT 1',
      variables: [Variable<String>(materialId), Variable<int>(pageNo)],
      readsFrom: {this.materialPages},
    ).asyncMap(this.materialPages.mapFromRow);
  }

  Selectable<EvidenceMaterialPageCurrentResult> evidenceMaterialPageCurrent(
    String materialId,
    int pageNo,
  ) {
    return customSelect(
      'SELECT mp.content, mp.label, mp.updated_at, m.title, m.source_file_name FROM material_page AS mp JOIN material AS m ON m.id = mp.material_id WHERE mp.material_id = ?1 AND mp.page_no = ?2 LIMIT 1',
      variables: [Variable<String>(materialId), Variable<int>(pageNo)],
      readsFrom: {this.materialPages, this.materials},
    ).map(
      (QueryRow row) => EvidenceMaterialPageCurrentResult(
        content: row.read<String>('content'),
        label: row.readNullable<String>('label'),
        updatedAt: row.read<String>('updated_at'),
        title: row.read<String>('title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
      ),
    );
  }

  Selectable<EvidenceMaterialPageSourcesResult> evidenceMaterialPageSources() {
    return customSelect(
      'SELECT mp.material_id, mp.page_no, mp.content, mp.updated_at FROM material_page AS mp ORDER BY mp.updated_at DESC, mp.material_id, mp.page_no',
      variables: [],
      readsFrom: {this.materialPages},
    ).map(
      (QueryRow row) => EvidenceMaterialPageSourcesResult(
        materialId: row.read<String>('material_id'),
        pageNo: row.read<int>('page_no'),
        content: row.read<String>('content'),
        updatedAt: row.read<String>('updated_at'),
      ),
    );
  }

  Selectable<EvidenceMaterialPageSourceResult> evidenceMaterialPageSource(
    String materialId,
    int pageNo,
  ) {
    return customSelect(
      'SELECT content, updated_at FROM material_page WHERE material_id = ?1 AND page_no = ?2 LIMIT 1',
      variables: [Variable<String>(materialId), Variable<int>(pageNo)],
      readsFrom: {this.materialPages},
    ).map(
      (QueryRow row) => EvidenceMaterialPageSourceResult(
        content: row.read<String>('content'),
        updatedAt: row.read<String>('updated_at'),
      ),
    );
  }

  Selectable<LearningGoalRow> activeGoals(String status) {
    return customSelect(
      'SELECT * FROM learning_goal WHERE status = ?1 ORDER BY due_date IS NULL, due_date, id DESC',
      variables: [Variable<String>(status)],
      readsFrom: {this.learningGoals},
    ).asyncMap(this.learningGoals.mapFromRow);
  }

  Selectable<LearningGoalRow> goalById(String id) {
    return customSelect(
      'SELECT * FROM learning_goal WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(id)],
      readsFrom: {this.learningGoals},
    ).asyncMap(this.learningGoals.mapFromRow);
  }

  Future<int> insertLearningGoal(
    String id,
    String title,
    String? scopeText,
    String? dueDate,
    String status,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO learning_goal (id, title, scope_text, due_date, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)',
      variables: [
        Variable<String>(id),
        Variable<String>(title),
        Variable<String>(scopeText),
        Variable<String>(dueDate),
        Variable<String>(status),
        Variable<String>(stamp),
      ],
      updates: {this.learningGoals},
    );
  }

  Future<int> setLearningGoalStatus(
    String status,
    String stamp,
    String goalId,
  ) {
    return customUpdate(
      'UPDATE learning_goal SET status = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(status),
        Variable<String>(stamp),
        Variable<String>(goalId),
      ],
      updates: {this.learningGoals},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<LearningGoalRow> goals(
    String activeStatus,
    String pausedStatus,
    String doneStatus,
  ) {
    return customSelect(
      'SELECT * FROM learning_goal ORDER BY CASE status WHEN ?1 THEN 0 WHEN ?2 THEN 1 WHEN ?3 THEN 2 ELSE 3 END, id DESC',
      variables: [
        Variable<String>(activeStatus),
        Variable<String>(pausedStatus),
        Variable<String>(doneStatus),
      ],
      readsFrom: {this.learningGoals},
    ).asyncMap(this.learningGoals.mapFromRow);
  }

  Selectable<ConversationByIdResult> conversationById(String conversationId) {
    return customSelect(
      'SELECT c.*, (SELECT title FROM material WHERE id = c.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, EXISTS (SELECT 1 AS _c0 FROM attempt AS a WHERE a.conversation_id = c.id) AS has_attempts, EXISTS (SELECT 1 AS _c1 FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL) AS has_draft FROM conversation AS c WHERE c.id = ?1 LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.materials, this.conversations, this.attempts},
    ).map(
      (QueryRow row) => ConversationByIdResult(
        id: row.read<String>('id'),
        title: row.readNullable<String>('title'),
        goalId: row.readNullable<String>('goal_id'),
        materialId: row.readNullable<String>('material_id'),
        pageNo: row.readNullable<int>('page_no'),
        sourceRef: row.readNullable<String>('source_ref'),
        contextText: row.readNullable<String>('context_text'),
        questionMessageId: row.readNullable<String>('question_message_id'),
        entryKind: row.read<String>('entry_kind'),
        status: row.read<String>('status'),
        endedAt: row.readNullable<String>('ended_at'),
        lastMessageAt: row.readNullable<String>('last_message_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        hasAttempts: row.read<bool>('has_attempts'),
        hasDraft: row.read<bool>('has_draft'),
      ),
    );
  }

  Selectable<ConversationQuestionResult> conversationQuestion(
    String conversationId,
  ) {
    return customSelect(
      'SELECT c.id, c.source_ref, c.context_text, c.page_no, c.created_at, c.updated_at, (SELECT title FROM material WHERE id = c.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS stem, (SELECT m.image_paths_json FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS image_paths_json FROM conversation AS c WHERE c.id = ?1 LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.conversations, this.materials, this.messages},
    ).map(
      (QueryRow row) => ConversationQuestionResult(
        id: row.read<String>('id'),
        sourceRef: row.readNullable<String>('source_ref'),
        contextText: row.readNullable<String>('context_text'),
        pageNo: row.readNullable<int>('page_no'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        stem: row.readNullable<String>('stem'),
        imagePathsJson: row.readNullable<String>('image_paths_json'),
      ),
    );
  }

  Selectable<QuestionRowsResult> questionRows(
    String? conversationIds,
    int? rowLimit,
  ) {
    return customSelect(
      'SELECT c.id, c.source_ref, c.context_text, c.page_no, c.created_at, c.updated_at, (SELECT title FROM material WHERE id = c.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS stem, (SELECT m.image_paths_json FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS image_paths_json, a.id AS last_attempt_id, a.session_id AS last_attempt_session_id, a.user_answer AS last_attempt_user_answer, a.solution AS last_attempt_solution, a.is_correct AS last_attempt_is_correct, a.independent AS last_attempt_independent, a.help_json AS last_attempt_help_json, a.feedback AS last_attempt_feedback, a.delayed AS last_attempt_delayed, a.submitted_at AS last_attempt_submitted_at, a.created_at AS last_attempt_created_at, EXISTS (SELECT 1 AS _c0 FROM attempt AS a3 WHERE a3.conversation_id = c.id AND a3.submitted_at IS NULL) AS has_draft FROM conversation AS c LEFT JOIN attempt AS a ON a.id = (SELECT a2.id FROM attempt AS a2 WHERE a2.conversation_id = c.id AND a2.submitted_at IS NOT NULL ORDER BY a2.submitted_at DESC, a2.id DESC LIMIT 1) WHERE EXISTS (SELECT 1 AS _c1 FROM attempt AS a3 WHERE a3.conversation_id = c.id) AND(?1 IS NULL OR c.id IN (SELECT value FROM json_each(?1)))ORDER BY c.updated_at DESC, c.id DESC LIMIT COALESCE(?2, -1)',
      variables: [Variable<String>(conversationIds), Variable<int>(rowLimit)],
      readsFrom: {
        this.conversations,
        this.materials,
        this.messages,
        this.attempts,
      },
    ).map(
      (QueryRow row) => QuestionRowsResult(
        id: row.read<String>('id'),
        sourceRef: row.readNullable<String>('source_ref'),
        contextText: row.readNullable<String>('context_text'),
        pageNo: row.readNullable<int>('page_no'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        stem: row.readNullable<String>('stem'),
        imagePathsJson: row.readNullable<String>('image_paths_json'),
        lastAttemptId: row.readNullable<String>('last_attempt_id'),
        lastAttemptSessionId: row.readNullable<String>(
          'last_attempt_session_id',
        ),
        lastAttemptUserAnswer: row.readNullable<String>(
          'last_attempt_user_answer',
        ),
        lastAttemptSolution: row.readNullable<String>('last_attempt_solution'),
        lastAttemptIsCorrect: row.readNullable<bool>('last_attempt_is_correct'),
        lastAttemptIndependent: row.readNullable<bool>(
          'last_attempt_independent',
        ),
        lastAttemptHelpJson: row.readNullable<String>('last_attempt_help_json'),
        lastAttemptFeedback: row.readNullable<String>('last_attempt_feedback'),
        lastAttemptDelayed: row.readNullable<bool>('last_attempt_delayed'),
        lastAttemptSubmittedAt: row.readNullable<String>(
          'last_attempt_submitted_at',
        ),
        lastAttemptCreatedAt: row.readNullable<String>(
          'last_attempt_created_at',
        ),
        hasDraft: row.read<bool>('has_draft'),
      ),
    );
  }

  Selectable<ConversationRecordsResult> conversationRecords(
    String? goalId,
    int unassignedOnly,
    String? answerStatus,
    int? rowLimit,
    int rowOffset,
  ) {
    return customSelect(
      'SELECT c.*, (SELECT COUNT(*) FROM message AS m WHERE m.conversation_id = c.id) AS message_count, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id ORDER BY m.id DESC LIMIT 1) AS preview, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' ORDER BY m.id DESC LIMIT 1) AS last_user_message, (SELECT a.user_answer FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL ORDER BY a.id DESC LIMIT 1) AS draft_answer, (SELECT a.updated_at FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL ORDER BY a.id DESC LIMIT 1) AS draft_updated_at, (SELECT title FROM material WHERE id = c.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, EXISTS (SELECT 1 AS _c0 FROM attempt AS a WHERE a.conversation_id = c.id) AS has_attempts, EXISTS (SELECT 1 AS _c1 FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL) AS has_draft FROM conversation AS c WHERE(?1 IS NULL OR c.goal_id = ?1)AND(?2 = 0 OR c.goal_id IS NULL)AND(?3 IS NULL OR(?3 = \'open\' AND EXISTS (SELECT 1 AS _c2 FROM attempt AS a WHERE a.conversation_id = c.id) AND NOT EXISTS (SELECT 1 AS _c3 FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NOT NULL))OR(?3 = \'correct\' AND EXISTS (SELECT 1 AS _c4 FROM attempt AS a WHERE a.conversation_id = c.id AND a.id = (SELECT a2.id FROM attempt AS a2 WHERE a2.conversation_id = c.id AND a2.submitted_at IS NOT NULL ORDER BY a2.submitted_at DESC, a2.id DESC LIMIT 1) AND a.is_correct = 1))OR(?3 = \'wrong\' AND EXISTS (SELECT 1 AS _c5 FROM attempt AS a WHERE a.conversation_id = c.id AND a.id = (SELECT a2.id FROM attempt AS a2 WHERE a2.conversation_id = c.id AND a2.submitted_at IS NOT NULL ORDER BY a2.submitted_at DESC, a2.id DESC LIMIT 1) AND a.is_correct = 0))OR(?3 = \'unjudged\' AND EXISTS (SELECT 1 AS _c6 FROM attempt AS a WHERE a.conversation_id = c.id AND a.id = (SELECT a2.id FROM attempt AS a2 WHERE a2.conversation_id = c.id AND a2.submitted_at IS NOT NULL ORDER BY a2.submitted_at DESC, a2.id DESC LIMIT 1) AND a.is_correct IS NULL)))ORDER BY c.updated_at DESC, c.id DESC LIMIT COALESCE(?4, -1) OFFSET ?5',
      variables: [
        Variable<String>(goalId),
        Variable<int>(unassignedOnly),
        Variable<String>(answerStatus),
        Variable<int>(rowLimit),
        Variable<int>(rowOffset),
      ],
      readsFrom: {
        this.messages,
        this.conversations,
        this.attempts,
        this.materials,
      },
    ).map(
      (QueryRow row) => ConversationRecordsResult(
        id: row.read<String>('id'),
        title: row.readNullable<String>('title'),
        goalId: row.readNullable<String>('goal_id'),
        materialId: row.readNullable<String>('material_id'),
        pageNo: row.readNullable<int>('page_no'),
        sourceRef: row.readNullable<String>('source_ref'),
        contextText: row.readNullable<String>('context_text'),
        questionMessageId: row.readNullable<String>('question_message_id'),
        entryKind: row.read<String>('entry_kind'),
        status: row.read<String>('status'),
        endedAt: row.readNullable<String>('ended_at'),
        lastMessageAt: row.readNullable<String>('last_message_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        messageCount: row.read<int>('message_count'),
        preview: row.readNullable<String>('preview'),
        lastUserMessage: row.readNullable<String>('last_user_message'),
        draftAnswer: row.readNullable<String>('draft_answer'),
        draftUpdatedAt: row.readNullable<String>('draft_updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        hasAttempts: row.read<bool>('has_attempts'),
        hasDraft: row.read<bool>('has_draft'),
      ),
    );
  }

  Selectable<RecentlyActiveRecordsResult> recentlyActiveRecords(int? limit) {
    return customSelect(
      'WITH candidates AS (SELECT id FROM (SELECT c.id AS id FROM conversation AS c ORDER BY c.updated_at DESC, c.id DESC LIMIT COALESCE(?1, -1)) UNION SELECT conversation_id FROM (SELECT a.conversation_id AS conversation_id FROM attempt AS a WHERE a.submitted_at IS NULL ORDER BY a.updated_at DESC, a.id DESC LIMIT COALESCE(?1, -1))) SELECT c.*, (SELECT COUNT(*) FROM message AS m WHERE m.conversation_id = c.id) AS message_count, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id ORDER BY m.id DESC LIMIT 1) AS preview, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' ORDER BY m.id DESC LIMIT 1) AS last_user_message, (SELECT a.user_answer FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL ORDER BY a.id DESC LIMIT 1) AS draft_answer, (SELECT a.updated_at FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL ORDER BY a.id DESC LIMIT 1) AS draft_updated_at, (SELECT title FROM material WHERE id = c.material_id) AS material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, EXISTS (SELECT 1 AS _c0 FROM attempt AS a WHERE a.conversation_id = c.id) AS has_attempts, EXISTS (SELECT 1 AS _c1 FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL) AS has_draft FROM conversation AS c JOIN candidates ON candidates.id = c.id ORDER BY max(c.updated_at, coalesce((SELECT a.updated_at FROM attempt AS a WHERE a.conversation_id = c.id AND a.submitted_at IS NULL ORDER BY a.id DESC LIMIT 1), c.updated_at)) DESC, c.id DESC LIMIT COALESCE(?1, -1)',
      variables: [Variable<int>(limit)],
      readsFrom: {
        this.conversations,
        this.attempts,
        this.messages,
        this.materials,
      },
    ).map(
      (QueryRow row) => RecentlyActiveRecordsResult(
        id: row.read<String>('id'),
        title: row.readNullable<String>('title'),
        goalId: row.readNullable<String>('goal_id'),
        materialId: row.readNullable<String>('material_id'),
        pageNo: row.readNullable<int>('page_no'),
        sourceRef: row.readNullable<String>('source_ref'),
        contextText: row.readNullable<String>('context_text'),
        questionMessageId: row.readNullable<String>('question_message_id'),
        entryKind: row.read<String>('entry_kind'),
        status: row.read<String>('status'),
        endedAt: row.readNullable<String>('ended_at'),
        lastMessageAt: row.readNullable<String>('last_message_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        messageCount: row.read<int>('message_count'),
        preview: row.readNullable<String>('preview'),
        lastUserMessage: row.readNullable<String>('last_user_message'),
        draftAnswer: row.readNullable<String>('draft_answer'),
        draftUpdatedAt: row.readNullable<String>('draft_updated_at'),
        materialTitle: row.readNullable<String>('material_title'),
        sourceFileName: row.readNullable<String>('source_file_name'),
        hasAttempts: row.read<bool>('has_attempts'),
        hasDraft: row.read<bool>('has_draft'),
      ),
    );
  }

  Future<int> insertConversationRecord(
    String id,
    String? title,
    String? goalId,
    String? materialId,
    int? pageNo,
    String? sourceRef,
    String? contextText,
    String entryKind,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO conversation (id, title, goal_id, material_id, page_no, source_ref, context_text, entry_kind, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, \'open\', ?9, ?9)',
      variables: [
        Variable<String>(id),
        Variable<String>(title),
        Variable<String>(goalId),
        Variable<String>(materialId),
        Variable<int>(pageNo),
        Variable<String>(sourceRef),
        Variable<String>(contextText),
        Variable<String>(entryKind),
        Variable<String>(stamp),
      ],
      updates: {this.conversations},
    );
  }

  Future<int> recordLastMessageTime(String stamp, String conversationId) {
    return customUpdate(
      'UPDATE conversation SET updated_at = ?1, last_message_at = ?1 WHERE id = ?2',
      variables: [Variable<String>(stamp), Variable<String>(conversationId)],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setConversationGoal(
    String? goalId,
    String stamp,
    String conversationId,
  ) {
    return customUpdate(
      'UPDATE conversation SET goal_id = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(goalId),
        Variable<String>(stamp),
        Variable<String>(conversationId),
      ],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setConversationMaterial(
    String? materialId,
    int? pageNo,
    String stamp,
    String conversationId,
  ) {
    return customUpdate(
      'UPDATE conversation SET material_id = ?1, page_no = ?2, updated_at = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(materialId),
        Variable<int>(pageNo),
        Variable<String>(stamp),
        Variable<String>(conversationId),
      ],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setQuestionMessage(String? messageId, String conversationId) {
    return customUpdate(
      'UPDATE conversation SET question_message_id = ?1 WHERE id = ?2',
      variables: [
        Variable<String>(messageId),
        Variable<String>(conversationId),
      ],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> endConversation(String? stamp, String conversationId) {
    return customUpdate(
      'UPDATE conversation SET status = \'ended\', ended_at = ?1, updated_at = ?1 WHERE id = ?2',
      variables: [Variable<String>(stamp), Variable<String>(conversationId)],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> deleteConversationRecord(String conversationId) {
    return customUpdate(
      'DELETE FROM conversation WHERE id = ?1',
      variables: [Variable<String>(conversationId)],
      updates: {this.conversations},
      updateKind: UpdateKind.delete,
    );
  }

  Future<int> reopenConversation(String stamp, String conversationId) {
    return customUpdate(
      'UPDATE conversation SET status = \'open\', ended_at = NULL, updated_at = ?1 WHERE id = ?2',
      variables: [Variable<String>(stamp), Variable<String>(conversationId)],
      updates: {this.conversations},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<EvidenceQuestionCurrentResult> evidenceQuestionCurrent(
    String conversationId,
  ) {
    return customSelect(
      'SELECT COALESCE(c.question_message_id, (SELECT m.id FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' ORDER BY m.id LIMIT 1)) AS question_message_id, COALESCE(c.source_ref,(CASE WHEN (SELECT title FROM material WHERE id = c.material_id) IS NOT NULL AND c.page_no IS NOT NULL THEN \'《\' || (SELECT title FROM material WHERE id = c.material_id) || \'》第 \' || c.page_no || \' 页\' END)) AS source_ref, c.title, c.context_text, c.page_no, c.created_at, c.updated_at, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id = COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)) LIMIT 1) AS stem FROM conversation AS c WHERE c.id = ?1 LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.conversations, this.messages, this.materials},
    ).map(
      (QueryRow row) => EvidenceQuestionCurrentResult(
        questionMessageId: row.readNullable<String>('question_message_id'),
        sourceRef: row.readNullable<String>('source_ref'),
        title: row.readNullable<String>('title'),
        contextText: row.readNullable<String>('context_text'),
        pageNo: row.readNullable<int>('page_no'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        stem: row.readNullable<String>('stem'),
      ),
    );
  }

  Selectable<AttemptSubmissionResult> attemptSubmission(String attemptId) {
    return customSelect(
      'SELECT id, submitted_at FROM attempt WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(attemptId)],
      readsFrom: {this.attempts},
    ).map(
      (QueryRow row) => AttemptSubmissionResult(
        id: row.read<String>('id'),
        submittedAt: row.readNullable<String>('submitted_at'),
      ),
    );
  }

  Selectable<AttemptRow> attemptsForConversation(String conversationId) {
    return customSelect(
      'SELECT * FROM attempt WHERE conversation_id = ?1 ORDER BY id DESC',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.attempts},
    ).asyncMap(this.attempts.mapFromRow);
  }

  Selectable<AttemptRow> priorFeedback(String conversationId, int rowLimit) {
    return customSelect(
      'SELECT * FROM attempt WHERE conversation_id = ?1 AND submitted_at IS NOT NULL AND feedback IS NOT NULL AND TRIM(feedback) <> \'\' ORDER BY submitted_at DESC, id DESC LIMIT ?2',
      variables: [Variable<String>(conversationId), Variable<int>(rowLimit)],
      readsFrom: {this.attempts},
    ).asyncMap(this.attempts.mapFromRow);
  }

  Selectable<AttemptRow> latestSubmittedAttempt(String conversationId) {
    return customSelect(
      'SELECT * FROM attempt WHERE conversation_id = ?1 AND submitted_at IS NOT NULL ORDER BY submitted_at DESC, id DESC LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.attempts},
    ).asyncMap(this.attempts.mapFromRow);
  }

  Selectable<AttemptRow> attemptById(String id) {
    return customSelect(
      'SELECT * FROM attempt WHERE id = ?1 LIMIT 1',
      variables: [Variable<String>(id)],
      readsFrom: {this.attempts},
    ).asyncMap(this.attempts.mapFromRow);
  }

  Selectable<AttemptRow> openAttempt(String conversationId) {
    return customSelect(
      'SELECT * FROM attempt WHERE conversation_id = ?1 AND submitted_at IS NULL ORDER BY id DESC LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.attempts},
    ).asyncMap(this.attempts.mapFromRow);
  }

  Selectable<String?> sessionGoalOfConversation(String conversationId) {
    return customSelect(
      'SELECT s.goal_id FROM attempt AS a JOIN study_session AS s ON s.id = a.session_id WHERE a.conversation_id = ?1 AND s.goal_id IS NOT NULL ORDER BY a.id DESC LIMIT 1',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.studySessions, this.attempts},
    ).map((QueryRow row) => row.readNullable<String>('goal_id'));
  }

  Future<int> insertOpenAttempt(
    String id,
    String conversationId,
    String? sessionId,
    String? redoOfAttemptId,
    bool delayed,
    String createdAt,
    String updatedAt,
  ) {
    return customInsert(
      'INSERT INTO attempt (id, conversation_id, session_id, redo_of_attempt_id, delayed, created_at, updated_at) SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE NOT EXISTS (SELECT 1 FROM attempt WHERE conversation_id = ?2 AND submitted_at IS NULL)',
      variables: [
        Variable<String>(id),
        Variable<String>(conversationId),
        Variable<String>(sessionId),
        Variable<String>(redoOfAttemptId),
        Variable<bool>(delayed),
        Variable<String>(createdAt),
        Variable<String>(updatedAt),
      ],
      updates: {this.attempts},
    );
  }

  Future<int> updateOpenAttemptContext(
    String? sessionId,
    String? redoOfAttemptId,
    bool? delayed,
    String stamp,
    String attemptId,
  ) {
    return customUpdate(
      'UPDATE attempt SET session_id = COALESCE(?1, session_id), redo_of_attempt_id = COALESCE(?2, redo_of_attempt_id), delayed = COALESCE(?3, delayed), updated_at = ?4 WHERE id = ?5 AND submitted_at IS NULL',
      variables: [
        Variable<String>(sessionId),
        Variable<String>(redoOfAttemptId),
        Variable<bool>(delayed),
        Variable<String>(stamp),
        Variable<String>(attemptId),
      ],
      updates: {this.attempts},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> saveOpenAttemptDraft(
    String? answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed,
    String? feedback,
    String stamp,
    String attemptId,
  ) {
    return customUpdate(
      'UPDATE attempt SET user_answer = ?1, solution = ?2, is_correct = ?3, independent = ?4, delayed = ?5, feedback = ?6, updated_at = ?7 WHERE id = ?8 AND submitted_at IS NULL',
      variables: [
        Variable<String>(answer),
        Variable<String>(solution),
        Variable<bool>(isCorrect),
        Variable<bool>(independent),
        Variable<bool>(delayed),
        Variable<String>(feedback),
        Variable<String>(stamp),
        Variable<String>(attemptId),
      ],
      updates: {this.attempts},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> setAttemptHelp(String? helpJson, String stamp, String attemptId) {
    return customUpdate(
      'UPDATE attempt SET help_json = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(helpJson),
        Variable<String>(stamp),
        Variable<String>(attemptId),
      ],
      updates: {this.attempts},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> submitOpenAttempt(
    String? answer,
    String? solution,
    bool? isCorrect,
    bool? independent,
    bool delayed,
    String? feedback,
    String? stamp,
    String attemptId,
  ) {
    return customUpdate(
      'UPDATE attempt SET user_answer = ?1, solution = ?2, is_correct = ?3, independent = ?4, delayed = ?5, feedback = ?6, submitted_at = ?7, updated_at = ?7 WHERE id = ?8 AND submitted_at IS NULL',
      variables: [
        Variable<String>(answer),
        Variable<String>(solution),
        Variable<bool>(isCorrect),
        Variable<bool>(independent),
        Variable<bool>(delayed),
        Variable<String>(feedback),
        Variable<String>(stamp),
        Variable<String>(attemptId),
      ],
      updates: {this.attempts},
      updateKind: UpdateKind.update,
    );
  }

  Selectable<String?> sessionIdsOfConversation(String conversationId) {
    return customSelect(
      'SELECT DISTINCT session_id FROM attempt WHERE conversation_id = ?1 AND session_id IS NOT NULL',
      variables: [Variable<String>(conversationId)],
      readsFrom: {this.attempts},
    ).map((QueryRow row) => row.readNullable<String>('session_id'));
  }

  Selectable<String> attemptsInSession(String? sessionId) {
    return customSelect(
      'SELECT id FROM attempt WHERE session_id = ?1 LIMIT 1',
      variables: [Variable<String>(sessionId)],
      readsFrom: {this.attempts},
    ).map((QueryRow row) => row.read<String>('id'));
  }

  Selectable<RecentSubmittedResult> recentSubmitted(
    String? goalId,
    String? materialId,
    String? conversationId,
    String broughtIds,
    int? rowLimit,
  ) {
    return customSelect(
      'SELECT a.id AS attempt_id, a.conversation_id AS attempt_conversation_id, a.session_id AS attempt_session_id, a.user_answer AS attempt_user_answer, a.solution AS attempt_solution, a.is_correct AS attempt_is_correct, a.independent AS attempt_independent, a.help_json AS attempt_help_json, a.feedback AS attempt_feedback, a.delayed AS attempt_delayed, a.submitted_at AS attempt_submitted_at, a.created_at AS attempt_created_at, c.id AS question_id, c.source_ref AS question_source_ref, c.context_text AS question_context_text, c.page_no AS question_page_no, c.created_at AS question_created_at, c.updated_at AS question_updated_at, (SELECT title FROM material WHERE id = c.material_id) AS question_material_title, (SELECT source_file_name FROM material WHERE id = c.material_id) AS source_file_name, (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS question_stem, (SELECT m.image_paths_json FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id =(COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)))LIMIT 1) AS question_image_paths_json FROM attempt AS a JOIN conversation AS c ON c.id = a.conversation_id WHERE a.submitted_at IS NOT NULL AND((?1 IS NOT NULL AND c.goal_id = ?1)OR(?2 IS NOT NULL AND c.material_id = ?2)OR(c.goal_id IS NULL AND c.material_id IS NULL AND(?1 IS NOT NULL OR ?2 IS NOT NULL OR(?3 IS NOT NULL AND c.id = ?3)OR a.id IN (SELECT value FROM json_each(?4))))OR((?1 IS NOT NULL OR ?2 IS NOT NULL)AND a.id IN (SELECT value FROM json_each(?4))))ORDER BY a.submitted_at DESC, a.id DESC LIMIT COALESCE(?5, -1)',
      variables: [
        Variable<String>(goalId),
        Variable<String>(materialId),
        Variable<String>(conversationId),
        Variable<String>(broughtIds),
        Variable<int>(rowLimit),
      ],
      readsFrom: {
        this.attempts,
        this.conversations,
        this.materials,
        this.messages,
      },
    ).map(
      (QueryRow row) => RecentSubmittedResult(
        attemptId: row.read<String>('attempt_id'),
        attemptConversationId: row.read<String>('attempt_conversation_id'),
        attemptSessionId: row.readNullable<String>('attempt_session_id'),
        attemptUserAnswer: row.readNullable<String>('attempt_user_answer'),
        attemptSolution: row.readNullable<String>('attempt_solution'),
        attemptIsCorrect: row.readNullable<bool>('attempt_is_correct'),
        attemptIndependent: row.readNullable<bool>('attempt_independent'),
        attemptHelpJson: row.readNullable<String>('attempt_help_json'),
        attemptFeedback: row.readNullable<String>('attempt_feedback'),
        attemptDelayed: row.read<bool>('attempt_delayed'),
        attemptSubmittedAt: row.readNullable<String>('attempt_submitted_at'),
        attemptCreatedAt: row.read<String>('attempt_created_at'),
        questionId: row.read<String>('question_id'),
        questionSourceRef: row.readNullable<String>('question_source_ref'),
        questionContextText: row.readNullable<String>('question_context_text'),
        questionPageNo: row.readNullable<int>('question_page_no'),
        questionCreatedAt: row.read<String>('question_created_at'),
        questionUpdatedAt: row.read<String>('question_updated_at'),
        questionMaterialTitle: row.readNullable<String>(
          'question_material_title',
        ),
        sourceFileName: row.readNullable<String>('source_file_name'),
        questionStem: row.readNullable<String>('question_stem'),
        questionImagePathsJson: row.readNullable<String>(
          'question_image_paths_json',
        ),
      ),
    );
  }

  Selectable<EvidenceAnswerCurrentResult> evidenceAnswerCurrent(
    String attemptId,
  ) {
    return customSelect(
      'SELECT a.id, a.conversation_id, a.user_answer, a.solution, a.feedback, a.submitted_at, c.title, c.source_ref FROM attempt AS a JOIN conversation AS c ON c.id = a.conversation_id WHERE a.id = ?1 AND a.submitted_at IS NOT NULL LIMIT 1',
      variables: [Variable<String>(attemptId)],
      readsFrom: {this.attempts, this.conversations},
    ).map(
      (QueryRow row) => EvidenceAnswerCurrentResult(
        id: row.read<String>('id'),
        conversationId: row.read<String>('conversation_id'),
        userAnswer: row.readNullable<String>('user_answer'),
        solution: row.readNullable<String>('solution'),
        feedback: row.readNullable<String>('feedback'),
        submittedAt: row.readNullable<String>('submitted_at'),
        title: row.readNullable<String>('title'),
        sourceRef: row.readNullable<String>('source_ref'),
      ),
    );
  }

  Selectable<EvidenceAnswerSourcesResult> evidenceAnswerSources() {
    return customSelect(
      'SELECT a.id, a.conversation_id, a.user_answer, a.solution, a.feedback, a.submitted_at, c.material_id FROM attempt AS a JOIN conversation AS c ON c.id = a.conversation_id WHERE a.submitted_at IS NOT NULL ORDER BY a.submitted_at DESC, a.id DESC',
      variables: [],
      readsFrom: {this.attempts, this.conversations},
    ).map(
      (QueryRow row) => EvidenceAnswerSourcesResult(
        id: row.read<String>('id'),
        conversationId: row.read<String>('conversation_id'),
        userAnswer: row.readNullable<String>('user_answer'),
        solution: row.readNullable<String>('solution'),
        feedback: row.readNullable<String>('feedback'),
        submittedAt: row.readNullable<String>('submitted_at'),
        materialId: row.readNullable<String>('material_id'),
      ),
    );
  }

  Selectable<EvidenceAnswerSourceResult> evidenceAnswerSource(
    String attemptId,
  ) {
    return customSelect(
      'SELECT user_answer, solution, feedback, submitted_at FROM attempt WHERE id = ?1 AND submitted_at IS NOT NULL LIMIT 1',
      variables: [Variable<String>(attemptId)],
      readsFrom: {this.attempts},
    ).map(
      (QueryRow row) => EvidenceAnswerSourceResult(
        userAnswer: row.readNullable<String>('user_answer'),
        solution: row.readNullable<String>('solution'),
        feedback: row.readNullable<String>('feedback'),
        submittedAt: row.readNullable<String>('submitted_at'),
      ),
    );
  }

  Selectable<EvidenceThreadAttemptsResult> evidenceThreadAttempts(
    String? conversationId,
    String? stem,
    String? materialId,
    int? pageNo,
    String? goalId,
    int includeUnassigned,
    String? from,
    String? to,
    int rowLimit,
  ) {
    return customSelect(
      'SELECT a.*, c.source_ref AS thread_source_ref, c.material_id AS thread_material_id, c.page_no AS thread_page_no, c.goal_id AS thread_goal_id, COALESCE((SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id = COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)) LIMIT 1), \'\') AS thread_stem FROM attempt AS a JOIN conversation AS c ON c.id = a.conversation_id WHERE a.submitted_at IS NOT NULL AND(?1 IS NULL OR c.id = ?1)AND(?2 IS NULL OR (SELECT m.content FROM message AS m WHERE m.conversation_id = c.id AND m.role = \'user\' AND m.id = COALESCE(c.question_message_id, (SELECT m2.id FROM message AS m2 WHERE m2.conversation_id = c.id AND m2.role = \'user\' ORDER BY m2.id LIMIT 1)) LIMIT 1) = ?2)AND(?3 IS NULL OR(c.material_id = ?3 AND(?4 IS NULL OR c.page_no = ?4)))AND(?5 IS NULL OR c.goal_id = ?5 OR(?6 = 1 AND c.goal_id IS NULL))AND(?7 IS NULL OR a.submitted_at >= ?7)AND(?8 IS NULL OR a.submitted_at < ?8)ORDER BY a.submitted_at DESC, a.id DESC LIMIT ?9',
      variables: [
        Variable<String>(conversationId),
        Variable<String>(stem),
        Variable<String>(materialId),
        Variable<int>(pageNo),
        Variable<String>(goalId),
        Variable<int>(includeUnassigned),
        Variable<String>(from),
        Variable<String>(to),
        Variable<int>(rowLimit),
      ],
      readsFrom: {this.conversations, this.messages, this.attempts},
    ).map(
      (QueryRow row) => EvidenceThreadAttemptsResult(
        id: row.read<String>('id'),
        conversationId: row.read<String>('conversation_id'),
        sessionId: row.readNullable<String>('session_id'),
        redoOfAttemptId: row.readNullable<String>('redo_of_attempt_id'),
        userAnswer: row.readNullable<String>('user_answer'),
        solution: row.readNullable<String>('solution'),
        isCorrect: row.readNullable<bool>('is_correct'),
        independent: row.readNullable<bool>('independent'),
        delayed: row.read<bool>('delayed'),
        helpJson: row.readNullable<String>('help_json'),
        feedback: row.readNullable<String>('feedback'),
        submittedAt: row.readNullable<String>('submitted_at'),
        createdAt: row.read<String>('created_at'),
        updatedAt: row.read<String>('updated_at'),
        threadSourceRef: row.readNullable<String>('thread_source_ref'),
        threadMaterialId: row.readNullable<String>('thread_material_id'),
        threadPageNo: row.readNullable<int>('thread_page_no'),
        threadGoalId: row.readNullable<String>('thread_goal_id'),
        threadStem: row.read<String>('thread_stem'),
      ),
    );
  }

  Selectable<AssessmentRow> assessmentsForAttempt(String attemptId) {
    return customSelect(
      'SELECT * FROM assessment WHERE attempt_id = ?1 ORDER BY id',
      variables: [Variable<String>(attemptId)],
      readsFrom: {this.assessments},
    ).asyncMap(this.assessments.mapFromRow);
  }

  Selectable<AssessmentRow> assessmentsForAttempts(String attemptIds) {
    return customSelect(
      'SELECT * FROM assessment WHERE attempt_id IN (SELECT value FROM json_each(?1)) ORDER BY id',
      variables: [Variable<String>(attemptIds)],
      readsFrom: {this.assessments},
    ).asyncMap(this.assessments.mapFromRow);
  }

  Selectable<AssessmentRow> latestAssessmentOfKind(
    String attemptId,
    String kind,
  ) {
    return customSelect(
      'SELECT * FROM assessment WHERE attempt_id = ?1 AND kind = ?2 ORDER BY id DESC LIMIT 1',
      variables: [Variable<String>(attemptId), Variable<String>(kind)],
      readsFrom: {this.assessments},
    ).asyncMap(this.assessments.mapFromRow);
  }

  Selectable<String> assessmentIdsOfKind(String attemptId, String kind) {
    return customSelect(
      'SELECT id FROM assessment WHERE attempt_id = ?1 AND kind = ?2 ORDER BY id DESC',
      variables: [Variable<String>(attemptId), Variable<String>(kind)],
      readsFrom: {this.assessments},
    ).map((QueryRow row) => row.read<String>('id'));
  }

  Future<int> deleteAssessmentsOfKind(String attemptId, String kind) {
    return customUpdate(
      'DELETE FROM assessment WHERE attempt_id = ?1 AND kind = ?2',
      variables: [Variable<String>(attemptId), Variable<String>(kind)],
      updates: {this.assessments},
      updateKind: UpdateKind.delete,
    );
  }

  Future<int> insertAssessment(
    String id,
    String attemptId,
    String kind,
    String result,
    String? basis,
    String stamp,
  ) {
    return customInsert(
      'INSERT INTO assessment (id, attempt_id, kind, result, basis, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)',
      variables: [
        Variable<String>(id),
        Variable<String>(attemptId),
        Variable<String>(kind),
        Variable<String>(result),
        Variable<String>(basis),
        Variable<String>(stamp),
      ],
      updates: {this.assessments},
    );
  }

  Future<int> updateAssessmentResult(
    String result,
    String stamp,
    String assessmentId,
  ) {
    return customUpdate(
      'UPDATE assessment SET result = ?1, updated_at = ?2 WHERE id = ?3',
      variables: [
        Variable<String>(result),
        Variable<String>(stamp),
        Variable<String>(assessmentId),
      ],
      updates: {this.assessments},
      updateKind: UpdateKind.update,
    );
  }

  Future<int> deleteAssessmentIds(String ids) {
    return customUpdate(
      'DELETE FROM assessment WHERE id IN (SELECT value FROM json_each(?1))',
      variables: [Variable<String>(ids)],
      updates: {this.assessments},
      updateKind: UpdateKind.delete,
    );
  }

  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    timetableEntries,
    appMeta,
    profiles,
    learningGoals,
    assetObjects,
    assetChunks,
    materials,
    materialPages,
    conversations,
    messages,
    studyPlans,
    planItems,
    scheduleBlocks,
    studySessions,
    attempts,
    assessments,
    memories,
    revisionCommits,
    revisionChanges,
    revisionRefs,
    revisionCheckpoints,
    revisionContexts,
    revisionSequences,
    idxAssetChunkHash,
    idxMaterialGoal,
    idxMaterialPageMaterial,
    idxConversationStatus,
    idxConversationGoal,
    idxConversationMaterial,
    idxMessageConversation,
    idxStudyPlanMaterial,
    idxPlanItemStatusDue,
    idxPlanItemGoal,
    idxPlanItemConversation,
    idxPlanItemStudySeq,
    idxScheduleStart,
    idxSchedulePlan,
    idxSessionPlan,
    idxSessionConversation,
    idxAttemptConversation,
    idxAttemptSession,
    idxAttemptRedo,
    idxAssessmentAttempt,
    idxMemoryStatus,
    idxMemoryValid,
    idxRevisionRequest,
    idxRevisionCommitParent,
    idxRevisionChangeTarget,
    idxRevisionChangeCommit,
    idxRevisionCheckpointCommit,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'asset_object',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('asset_chunk', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'learning_goal',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('material', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'material',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('material_page', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'learning_goal',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('conversation', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'material',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('conversation', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversation',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('message', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'material',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_plan', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'learning_goal',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_plan', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversation',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_plan', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'learning_goal',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('plan_item', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversation',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('plan_item', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'study_plan',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('plan_item', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'plan_item',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('schedule_block', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'learning_goal',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_session', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'plan_item',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_session', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversation',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('study_session', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversation',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('attempt', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'study_session',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('attempt', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'attempt',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('attempt', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'attempt',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('assessment', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'revision_commit',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('revision_commit', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'revision_commit',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('revision_change', kind: UpdateKind.delete)],
    ),
  ]);
}

class TimetableEntriesOnWeekdayResult {
  final String startTime;
  final String endTime;
  final String title;
  final String? location;
  TimetableEntriesOnWeekdayResult({
    required this.startTime,
    required this.endTime,
    required this.title,
    this.location,
  });
}

class PlanRowsResult {
  final String id;
  final String? materialId;
  final String? goalId;
  final String? conversationId;
  final String title;
  final int? pageFrom;
  final int? pageTo;
  final int? currentPage;
  final String status;
  final String createdAt;
  final String updatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final int stepsDone;
  final int stepsTotal;
  final String? nextStepTitle;
  PlanRowsResult({
    required this.id,
    this.materialId,
    this.goalId,
    this.conversationId,
    required this.title,
    this.pageFrom,
    this.pageTo,
    this.currentPage,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.materialTitle,
    this.sourceFileName,
    required this.stepsDone,
    required this.stepsTotal,
    this.nextStepTitle,
  });
}

class BlocksOverlappingResult {
  final String id;
  final String planItemId;
  final String startAt;
  final String endAt;
  final String source;
  final String status;
  final bool locked;
  final String createdAt;
  final String updatedAt;
  final String pTitle;
  final String? pNote;
  final String pStatus;
  BlocksOverlappingResult({
    required this.id,
    required this.planItemId,
    required this.startAt,
    required this.endAt,
    required this.source,
    required this.status,
    required this.locked,
    required this.createdAt,
    required this.updatedAt,
    required this.pTitle,
    this.pNote,
    required this.pStatus,
  });
}

class NextPlannedBlockResult {
  final String id;
  final String planItemId;
  final String startAt;
  final String endAt;
  final String source;
  final String status;
  final bool locked;
  final String createdAt;
  final String updatedAt;
  final String pTitle;
  final String? pNote;
  final String pStatus;
  NextPlannedBlockResult({
    required this.id,
    required this.planItemId,
    required this.startAt,
    required this.endAt,
    required this.source,
    required this.status,
    required this.locked,
    required this.createdAt,
    required this.updatedAt,
    required this.pTitle,
    this.pNote,
    required this.pStatus,
  });
}

class PlannedBlockSpansResult {
  final String id;
  final String startAt;
  final String endAt;
  final String title;
  PlannedBlockSpansResult({
    required this.id,
    required this.startAt,
    required this.endAt,
    required this.title,
  });
}

class FindOverlappingBlocksResult {
  final String startAt;
  final String endAt;
  final String title;
  FindOverlappingBlocksResult({
    required this.startAt,
    required this.endAt,
    required this.title,
  });
}

class PlannedBlocksAfterResult {
  final String startAt;
  final String endAt;
  final String title;
  PlannedBlocksAfterResult({
    required this.startAt,
    required this.endAt,
    required this.title,
  });
}

class ItemByConversationAndTitleResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemByConversationAndTitleResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemPlanResult {
  final String id;
  final String? studyPlanId;
  ItemPlanResult({required this.id, this.studyPlanId});
}

class PlanStepsResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  PlanStepsResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class PlanStepsForPlansResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  PlanStepsForPlansResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemsResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemsResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemByIdResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemByIdResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemByConversationResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemByConversationResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemByConversationAndStepResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemByConversationAndStepResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class DoneItemsResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  DoneItemsResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class ItemsByIdsResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  ItemsByIdsResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class NextDueItemResult {
  final String id;
  final String? goalId;
  final String? conversationId;
  final String? studyPlanId;
  final int? seq;
  final String title;
  final String? note;
  final int? pageFrom;
  final int? pageTo;
  final String? dueAt;
  final int? estMinutes;
  final int priority;
  final String status;
  final String source;
  final String? originJson;
  final String? completedAt;
  final String createdAt;
  final String updatedAt;
  final String? sourceFileName;
  NextDueItemResult({
    required this.id,
    this.goalId,
    this.conversationId,
    this.studyPlanId,
    this.seq,
    required this.title,
    this.note,
    this.pageFrom,
    this.pageTo,
    this.dueAt,
    this.estMinutes,
    required this.priority,
    required this.status,
    required this.source,
    this.originJson,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileName,
  });
}

class EvidenceMessageCurrentResult {
  final String content;
  final String createdAt;
  final String conversationId;
  final String? title;
  final String? goalId;
  final String? materialId;
  EvidenceMessageCurrentResult({
    required this.content,
    required this.createdAt,
    required this.conversationId,
    this.title,
    this.goalId,
    this.materialId,
  });
}

class EvidenceMessageSourcesResult {
  final String id;
  final String conversationId;
  final String content;
  final String createdAt;
  final String? materialId;
  EvidenceMessageSourcesResult({
    required this.id,
    required this.conversationId,
    required this.content,
    required this.createdAt,
    this.materialId,
  });
}

class EvidenceMessageSourceResult {
  final String content;
  final String createdAt;
  EvidenceMessageSourceResult({required this.content, required this.createdAt});
}

class ActiveDifficultiesResult {
  final String id;
  final String content;
  ActiveDifficultiesResult({required this.id, required this.content});
}

class ActiveMemoryIdentitiesResult {
  final String kind;
  final String? scope;
  final String content;
  ActiveMemoryIdentitiesResult({
    required this.kind,
    this.scope,
    required this.content,
  });
}

class MaterialByIdResult {
  final String id;
  final String title;
  final String kind;
  final String? sourceRef;
  final String? sourceFileName;
  final String? sourceFileHash;
  final String? goalId;
  final String createdAt;
  final String updatedAt;
  final int pageCount;
  MaterialByIdResult({
    required this.id,
    required this.title,
    required this.kind,
    this.sourceRef,
    this.sourceFileName,
    this.sourceFileHash,
    this.goalId,
    required this.createdAt,
    required this.updatedAt,
    required this.pageCount,
  });
}

class MaterialListResult {
  final String id;
  final String title;
  final String kind;
  final String? sourceRef;
  final String? sourceFileName;
  final String? sourceFileHash;
  final String? goalId;
  final String createdAt;
  final String updatedAt;
  final int pageCount;
  MaterialListResult({
    required this.id,
    required this.title,
    required this.kind,
    this.sourceRef,
    this.sourceFileName,
    this.sourceFileHash,
    this.goalId,
    required this.createdAt,
    required this.updatedAt,
    required this.pageCount,
  });
}

class MaterialPageBoundsResult {
  final int? firstPage;
  final int? lastPage;
  MaterialPageBoundsResult({this.firstPage, this.lastPage});
}

class EvidenceMaterialPageCurrentResult {
  final String content;
  final String? label;
  final String updatedAt;
  final String title;
  final String? sourceFileName;
  EvidenceMaterialPageCurrentResult({
    required this.content,
    this.label,
    required this.updatedAt,
    required this.title,
    this.sourceFileName,
  });
}

class EvidenceMaterialPageSourcesResult {
  final String materialId;
  final int pageNo;
  final String content;
  final String updatedAt;
  EvidenceMaterialPageSourcesResult({
    required this.materialId,
    required this.pageNo,
    required this.content,
    required this.updatedAt,
  });
}

class EvidenceMaterialPageSourceResult {
  final String content;
  final String updatedAt;
  EvidenceMaterialPageSourceResult({
    required this.content,
    required this.updatedAt,
  });
}

class ConversationByIdResult {
  final String id;
  final String? title;
  final String? goalId;
  final String? materialId;
  final int? pageNo;
  final String? sourceRef;
  final String? contextText;
  final String? questionMessageId;
  final String entryKind;
  final String status;
  final String? endedAt;
  final String? lastMessageAt;
  final String createdAt;
  final String updatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final bool hasAttempts;
  final bool hasDraft;
  ConversationByIdResult({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.sourceRef,
    this.contextText,
    this.questionMessageId,
    required this.entryKind,
    required this.status,
    this.endedAt,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
    this.materialTitle,
    this.sourceFileName,
    required this.hasAttempts,
    required this.hasDraft,
  });
}

class ConversationQuestionResult {
  final String id;
  final String? sourceRef;
  final String? contextText;
  final int? pageNo;
  final String createdAt;
  final String updatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final String? stem;
  final String? imagePathsJson;
  ConversationQuestionResult({
    required this.id,
    this.sourceRef,
    this.contextText,
    this.pageNo,
    required this.createdAt,
    required this.updatedAt,
    this.materialTitle,
    this.sourceFileName,
    this.stem,
    this.imagePathsJson,
  });
}

class QuestionRowsResult {
  final String id;
  final String? sourceRef;
  final String? contextText;
  final int? pageNo;
  final String createdAt;
  final String updatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final String? stem;
  final String? imagePathsJson;
  final String? lastAttemptId;
  final String? lastAttemptSessionId;
  final String? lastAttemptUserAnswer;
  final String? lastAttemptSolution;
  final bool? lastAttemptIsCorrect;
  final bool? lastAttemptIndependent;
  final String? lastAttemptHelpJson;
  final String? lastAttemptFeedback;
  final bool? lastAttemptDelayed;
  final String? lastAttemptSubmittedAt;
  final String? lastAttemptCreatedAt;
  final bool hasDraft;
  QuestionRowsResult({
    required this.id,
    this.sourceRef,
    this.contextText,
    this.pageNo,
    required this.createdAt,
    required this.updatedAt,
    this.materialTitle,
    this.sourceFileName,
    this.stem,
    this.imagePathsJson,
    this.lastAttemptId,
    this.lastAttemptSessionId,
    this.lastAttemptUserAnswer,
    this.lastAttemptSolution,
    this.lastAttemptIsCorrect,
    this.lastAttemptIndependent,
    this.lastAttemptHelpJson,
    this.lastAttemptFeedback,
    this.lastAttemptDelayed,
    this.lastAttemptSubmittedAt,
    this.lastAttemptCreatedAt,
    required this.hasDraft,
  });
}

class ConversationRecordsResult {
  final String id;
  final String? title;
  final String? goalId;
  final String? materialId;
  final int? pageNo;
  final String? sourceRef;
  final String? contextText;
  final String? questionMessageId;
  final String entryKind;
  final String status;
  final String? endedAt;
  final String? lastMessageAt;
  final String createdAt;
  final String updatedAt;
  final int messageCount;
  final String? preview;
  final String? lastUserMessage;
  final String? draftAnswer;
  final String? draftUpdatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final bool hasAttempts;
  final bool hasDraft;
  ConversationRecordsResult({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.sourceRef,
    this.contextText,
    this.questionMessageId,
    required this.entryKind,
    required this.status,
    this.endedAt,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
    this.preview,
    this.lastUserMessage,
    this.draftAnswer,
    this.draftUpdatedAt,
    this.materialTitle,
    this.sourceFileName,
    required this.hasAttempts,
    required this.hasDraft,
  });
}

class RecentlyActiveRecordsResult {
  final String id;
  final String? title;
  final String? goalId;
  final String? materialId;
  final int? pageNo;
  final String? sourceRef;
  final String? contextText;
  final String? questionMessageId;
  final String entryKind;
  final String status;
  final String? endedAt;
  final String? lastMessageAt;
  final String createdAt;
  final String updatedAt;
  final int messageCount;
  final String? preview;
  final String? lastUserMessage;
  final String? draftAnswer;
  final String? draftUpdatedAt;
  final String? materialTitle;
  final String? sourceFileName;
  final bool hasAttempts;
  final bool hasDraft;
  RecentlyActiveRecordsResult({
    required this.id,
    this.title,
    this.goalId,
    this.materialId,
    this.pageNo,
    this.sourceRef,
    this.contextText,
    this.questionMessageId,
    required this.entryKind,
    required this.status,
    this.endedAt,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
    this.preview,
    this.lastUserMessage,
    this.draftAnswer,
    this.draftUpdatedAt,
    this.materialTitle,
    this.sourceFileName,
    required this.hasAttempts,
    required this.hasDraft,
  });
}

class EvidenceQuestionCurrentResult {
  final String? questionMessageId;
  final String? sourceRef;
  final String? title;
  final String? contextText;
  final int? pageNo;
  final String createdAt;
  final String updatedAt;
  final String? stem;
  EvidenceQuestionCurrentResult({
    this.questionMessageId,
    this.sourceRef,
    this.title,
    this.contextText,
    this.pageNo,
    required this.createdAt,
    required this.updatedAt,
    this.stem,
  });
}

class AttemptSubmissionResult {
  final String id;
  final String? submittedAt;
  AttemptSubmissionResult({required this.id, this.submittedAt});
}

class RecentSubmittedResult {
  final String attemptId;
  final String attemptConversationId;
  final String? attemptSessionId;
  final String? attemptUserAnswer;
  final String? attemptSolution;
  final bool? attemptIsCorrect;
  final bool? attemptIndependent;
  final String? attemptHelpJson;
  final String? attemptFeedback;
  final bool attemptDelayed;
  final String? attemptSubmittedAt;
  final String attemptCreatedAt;
  final String questionId;
  final String? questionSourceRef;
  final String? questionContextText;
  final int? questionPageNo;
  final String questionCreatedAt;
  final String questionUpdatedAt;
  final String? questionMaterialTitle;
  final String? sourceFileName;
  final String? questionStem;
  final String? questionImagePathsJson;
  RecentSubmittedResult({
    required this.attemptId,
    required this.attemptConversationId,
    this.attemptSessionId,
    this.attemptUserAnswer,
    this.attemptSolution,
    this.attemptIsCorrect,
    this.attemptIndependent,
    this.attemptHelpJson,
    this.attemptFeedback,
    required this.attemptDelayed,
    this.attemptSubmittedAt,
    required this.attemptCreatedAt,
    required this.questionId,
    this.questionSourceRef,
    this.questionContextText,
    this.questionPageNo,
    required this.questionCreatedAt,
    required this.questionUpdatedAt,
    this.questionMaterialTitle,
    this.sourceFileName,
    this.questionStem,
    this.questionImagePathsJson,
  });
}

class EvidenceAnswerCurrentResult {
  final String id;
  final String conversationId;
  final String? userAnswer;
  final String? solution;
  final String? feedback;
  final String? submittedAt;
  final String? title;
  final String? sourceRef;
  EvidenceAnswerCurrentResult({
    required this.id,
    required this.conversationId,
    this.userAnswer,
    this.solution,
    this.feedback,
    this.submittedAt,
    this.title,
    this.sourceRef,
  });
}

class EvidenceAnswerSourcesResult {
  final String id;
  final String conversationId;
  final String? userAnswer;
  final String? solution;
  final String? feedback;
  final String? submittedAt;
  final String? materialId;
  EvidenceAnswerSourcesResult({
    required this.id,
    required this.conversationId,
    this.userAnswer,
    this.solution,
    this.feedback,
    this.submittedAt,
    this.materialId,
  });
}

class EvidenceAnswerSourceResult {
  final String? userAnswer;
  final String? solution;
  final String? feedback;
  final String? submittedAt;
  EvidenceAnswerSourceResult({
    this.userAnswer,
    this.solution,
    this.feedback,
    this.submittedAt,
  });
}

class EvidenceThreadAttemptsResult {
  final String id;
  final String conversationId;
  final String? sessionId;
  final String? redoOfAttemptId;
  final String? userAnswer;
  final String? solution;
  final bool? isCorrect;
  final bool? independent;
  final bool delayed;
  final String? helpJson;
  final String? feedback;
  final String? submittedAt;
  final String createdAt;
  final String updatedAt;
  final String? threadSourceRef;
  final String? threadMaterialId;
  final int? threadPageNo;
  final String? threadGoalId;
  final String threadStem;
  EvidenceThreadAttemptsResult({
    required this.id,
    required this.conversationId,
    this.sessionId,
    this.redoOfAttemptId,
    this.userAnswer,
    this.solution,
    this.isCorrect,
    this.independent,
    required this.delayed,
    this.helpJson,
    this.feedback,
    this.submittedAt,
    required this.createdAt,
    required this.updatedAt,
    this.threadSourceRef,
    this.threadMaterialId,
    this.threadPageNo,
    this.threadGoalId,
    required this.threadStem,
  });
}
