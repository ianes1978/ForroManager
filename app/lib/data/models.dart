/// Modelli dei dati restituiti dall'API. Gli importi sono sempre in centesimi.
library;

typedef Json = Map<String, dynamic>;

class SessionUser {
  SessionUser({required this.id, required this.email, required this.name, required this.mustChangePassword});
  factory SessionUser.fromJson(Json j) => SessionUser(
        id: j['id'] as int,
        email: j['email'] as String,
        name: j['name'] as String,
        mustChangePassword: j['mustChangePassword'] as bool,
      );
  final int id;
  final String email;
  final String name;
  final bool mustChangePassword;

  SessionUser copyWith({bool? mustChangePassword}) => SessionUser(
      id: id, email: email, name: name, mustChangePassword: mustChangePassword ?? this.mustChangePassword);
}

class AppUser {
  AppUser({required this.id, required this.email, required this.name, required this.active, required this.mustChangePassword});
  factory AppUser.fromJson(Json j) => AppUser(
        id: j['id'] as int,
        email: j['email'] as String,
        name: j['name'] as String,
        active: j['active'] as bool,
        mustChangePassword: j['mustChangePassword'] as bool,
      );
  final int id;
  final String email;
  final String name;
  final bool active;
  final bool mustChangePassword;
}

class CategoryRef {
  CategoryRef(this.id, this.name);
  factory CategoryRef.fromJson(Json j) => CategoryRef(j['id'] as int, j['name'] as String);
  final int id;
  final String name;
}

class MemberSummary {
  MemberSummary({
    required this.arrearsCents,
    required this.arrearsCount,
    required this.openChargesCents,
    required this.openChargesCount,
    required this.missingForms,
    required this.inRegola,
  });
  factory MemberSummary.fromJson(Json j) => MemberSummary(
        arrearsCents: j['arrearsCents'] as int,
        arrearsCount: j['arrearsCount'] as int,
        openChargesCents: j['openChargesCents'] as int,
        openChargesCount: j['openChargesCount'] as int,
        missingForms: (j['missingForms'] as int?) ?? 0,
        inRegola: j['inRegola'] as bool,
      );
  final int arrearsCents;
  final int arrearsCount;
  final int openChargesCents;
  final int openChargesCount;
  final int missingForms;
  final bool inRegola;
}

class Suspension {
  Suspension({required this.id, required this.from, required this.to, this.reason});
  factory Suspension.fromJson(Json j) =>
      Suspension(id: j['id'] as int, from: j['from'] as String, to: j['to'] as String, reason: j['reason'] as String?);
  final int id;
  final String from;
  final String to;
  final String? reason;
}

class Member {
  Member({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.email,
    this.phone,
    required this.joinedOn,
    required this.status,
    this.ceasedOn,
    this.notes,
    required this.annualCategory,
    required this.monthlyCategory,
    this.summary,
    this.suspensions = const [],
  });
  factory Member.fromJson(Json j) => Member(
        id: j['id'] as int,
        firstName: j['firstName'] as String,
        lastName: j['lastName'] as String,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        joinedOn: j['joinedOn'] as String,
        status: j['status'] as String,
        ceasedOn: j['ceasedOn'] as String?,
        notes: j['notes'] as String?,
        annualCategory: CategoryRef.fromJson(j['annualCategory'] as Json),
        monthlyCategory: CategoryRef.fromJson(j['monthlyCategory'] as Json),
        summary: j['summary'] == null ? null : MemberSummary.fromJson(j['summary'] as Json),
        suspensions: [for (final s in (j['suspensions'] as List?) ?? const []) Suspension.fromJson(s as Json)],
      );
  final int id;
  final String firstName;
  final String lastName;
  final String? email;
  final String? phone;
  final String joinedOn;
  final String status;
  final String? ceasedOn;
  final String? notes;
  final CategoryRef annualCategory;
  final CategoryRef monthlyCategory;
  final MemberSummary? summary;
  final List<Suspension> suspensions;

  bool get active => status == 'attivo';
  String get fullName => '$lastName $firstName';
  String get initials => '${firstName.isEmpty ? '' : firstName[0]}${lastName.isEmpty ? '' : lastName[0]}'.toUpperCase();
}

class Due {
  Due({
    required this.id,
    required this.kind,
    required this.year,
    this.month,
    required this.label,
    this.categoryId,
    this.productId,
    required this.baseAmountCents,
    required this.amountCents,
    this.adjustmentReason,
    required this.paidCents,
    required this.remainingCents,
    required this.status,
    required this.chargedOn,
  });
  factory Due.fromJson(Json j) => Due(
        id: j['id'] as int,
        kind: j['kind'] as String,
        year: j['year'] as int,
        month: j['month'] as int?,
        label: j['label'] as String,
        categoryId: j['categoryId'] as int?,
        productId: j['productId'] as int?,
        baseAmountCents: j['baseAmountCents'] as int,
        amountCents: j['amountCents'] as int,
        adjustmentReason: j['adjustmentReason'] as String?,
        paidCents: j['paidCents'] as int,
        remainingCents: j['remainingCents'] as int,
        status: j['status'] as String,
        chargedOn: j['chargedOn'] as String,
      );
  final int id;
  final String kind; // annuale | mensile | prodotto
  final int year;
  final int? month;
  final String label;
  final int? categoryId;
  final int? productId;
  final int baseAmountCents;
  final int amountCents;
  final String? adjustmentReason;
  final int paidCents;
  final int remainingCents;
  final String status; // pagata | parziale | da_pagare | futura
  final String chargedOn;

  bool get isOpen => remainingCents > 0;
  bool get isReduced => amountCents != baseAmountCents;
}

class MemberDues {
  MemberDues({required this.year, required this.items, required this.summary});
  factory MemberDues.fromJson(Json j) => MemberDues(
        year: j['year'] as int,
        items: [for (final d in j['items'] as List) Due.fromJson(d as Json)],
        summary: MemberSummary.fromJson(j['summary'] as Json),
      );
  final int year;
  final List<Due> items;
  final MemberSummary summary;
}

class PaymentAllocation {
  PaymentAllocation(this.dueId, this.label, this.amountCents);
  factory PaymentAllocation.fromJson(Json j) =>
      PaymentAllocation(j['dueId'] as int, j['label'] as String, j['amountCents'] as int);
  final int dueId;
  final String label;
  final int amountCents;
}

class Payment {
  Payment({
    required this.id,
    required this.memberId,
    required this.memberName,
    required this.paidOn,
    required this.amountCents,
    required this.methodCode,
    required this.methodLabel,
    this.note,
    required this.recordedBy,
    required this.createdAt,
    required this.voided,
    this.voidReason,
    required this.allocations,
    required this.description,
  });
  factory Payment.fromJson(Json j) => Payment(
        id: j['id'] as int,
        memberId: j['memberId'] as int,
        memberName: j['memberName'] as String,
        paidOn: j['paidOn'] as String,
        amountCents: j['amountCents'] as int,
        methodCode: (j['method'] as Json)['code'] as String,
        methodLabel: (j['method'] as Json)['label'] as String,
        note: j['note'] as String?,
        recordedBy: (j['recordedBy'] as Json)['name'] as String,
        createdAt: j['createdAt'] as String,
        voided: j['voided'] as bool,
        voidReason: j['voidReason'] as String?,
        allocations: [for (final a in j['allocations'] as List) PaymentAllocation.fromJson(a as Json)],
        description: j['description'] as String,
      );
  final int id;
  final int memberId;
  final String memberName;
  final String paidOn;
  final int amountCents;
  final String methodCode;
  final String methodLabel;
  final String? note;
  final String recordedBy;
  final String createdAt;
  final bool voided;
  final String? voidReason;
  final List<PaymentAllocation> allocations;
  final String description;
}

class PaymentMethod {
  PaymentMethod(this.code, this.label, this.active);
  factory PaymentMethod.fromJson(Json j) => PaymentMethod(j['code'] as String, j['label'] as String, j['active'] as bool);
  final String code;
  final String label;
  final bool active;
}

class Fee {
  Fee({required this.categoryId, required this.kind, required this.name, this.months, required this.active, required this.year, this.amountCents});
  factory Fee.fromJson(Json j) => Fee(
        categoryId: j['categoryId'] as int,
        kind: j['kind'] as String,
        name: j['name'] as String,
        months: j['months'] as int?,
        active: j['active'] as bool,
        year: j['year'] as int,
        amountCents: j['amountCents'] as int?,
      );
  final int categoryId;
  final String kind; // annuale | mensile | pacchetto
  final String name;
  final int? months;
  final bool active;
  final int year;
  final int? amountCents;

  String get title => switch (kind) {
        'annuale' => 'Associativa ${name.toLowerCase()}',
        'mensile' => 'Mensile ${name.toLowerCase()}',
        _ => 'Pacchetto ${name.toLowerCase()}',
      };
}

class Product {
  Product({required this.id, required this.name, required this.type, required this.priceCents, required this.active});
  factory Product.fromJson(Json j) => Product(
        id: j['id'] as int,
        name: j['name'] as String,
        type: j['type'] as String,
        priceCents: j['priceCents'] as int,
        active: j['active'] as bool,
      );
  final int id;
  final String name;
  final String type;
  final int priceCents;
  final bool active;

  String get typeLabel => switch (type) {
        'stage' => 'Stage',
        'evento' => 'Evento',
        'merchandising' => 'Merchandising',
        _ => 'Altro',
      };
}

class FormDef {
  FormDef({required this.id, required this.name, required this.required, required this.active, required this.delivered, required this.returned});
  factory FormDef.fromJson(Json j) => FormDef(
        id: j['id'] as int,
        name: j['name'] as String,
        required: j['required'] as bool,
        active: j['active'] as bool,
        delivered: j['delivered'] as int,
        returned: j['returned'] as int,
      );
  final int id;
  final String name;
  final bool required;
  final bool active;
  final int delivered;
  final int returned;
}

class MemberForm {
  MemberForm({required this.formId, required this.formName, required this.required, this.deliveredOn, this.returnedOn});
  factory MemberForm.fromJson(Json j) => MemberForm(
        formId: j['formId'] as int,
        formName: j['formName'] as String,
        required: j['required'] as bool,
        deliveredOn: j['deliveredOn'] as String?,
        returnedOn: j['returnedOn'] as String?,
      );
  final int formId;
  final String formName;
  final bool required;
  final String? deliveredOn;
  final String? returnedOn;
}

class FormMember {
  FormMember({required this.memberId, required this.name, required this.deliveredOn, this.returnedOn});
  factory FormMember.fromJson(Json j) => FormMember(
        memberId: j['memberId'] as int,
        name: j['name'] as String,
        deliveredOn: j['deliveredOn'] as String,
        returnedOn: j['returnedOn'] as String?,
      );
  final int memberId;
  final String name;
  final String deliveredOn;
  final String? returnedOn;
}

class StatusReport {
  StatusReport({
    required this.activeMembers,
    required this.inRegola,
    required this.notInRegola,
    required this.arrearsTotalCents,
    required this.openChargesTotalCents,
    required this.members,
  });
  factory StatusReport.fromJson(Json j) => StatusReport(
        activeMembers: j['activeMembers'] as int,
        inRegola: j['inRegola'] as int,
        notInRegola: j['notInRegola'] as int,
        arrearsTotalCents: j['arrearsTotalCents'] as int,
        openChargesTotalCents: j['openChargesTotalCents'] as int,
        members: [
          for (final m in j['members'] as List)
            StatusMember((m as Json)['id'] as int, m['name'] as String, m['arrearsCents'] as int, m['arrearsCount'] as int,
                m['openChargesCents'] as int),
        ],
      );
  final int activeMembers;
  final int inRegola;
  final int notInRegola;
  final int arrearsTotalCents;
  final int openChargesTotalCents;
  final List<StatusMember> members;
}

class StatusMember {
  StatusMember(this.id, this.name, this.arrearsCents, this.arrearsCount, this.openChargesCents);
  final int id;
  final String name;
  final int arrearsCents;
  final int arrearsCount;
  final int openChargesCents;
}

class IncomeReport {
  IncomeReport({required this.year, required this.totalCents, required this.byMonth, required this.byMethod, required this.byKind});
  factory IncomeReport.fromJson(Json j) => IncomeReport(
        year: j['year'] as int,
        totalCents: j['totalCents'] as int,
        byMonth: [for (final v in j['byMonth'] as List) v as int],
        byMethod: [for (final m in j['byMethod'] as List) ((m as Json)['label'] as String, m['cents'] as int)],
        byKind: {for (final e in (j['byKind'] as Json).entries) e.key: e.value as int},
      );
  final int year;
  final int totalCents;
  final List<int> byMonth;
  final List<(String, int)> byMethod;
  final Map<String, int> byKind;
}

class AuditEntry {
  AuditEntry({required this.id, required this.at, this.userName, required this.description, required this.entity, this.entityId});
  factory AuditEntry.fromJson(Json j) => AuditEntry(
        id: j['id'] as int,
        at: j['at'] as String,
        userName: (j['user'] as Json?)?['name'] as String?,
        description: j['description'] as String,
        entity: j['entity'] as String,
        entityId: j['entityId'] as int?,
      );
  final int id;
  final String at;
  final String? userName;
  final String description;
  final String entity;
  final int? entityId;
}

class GenerateResult {
  GenerateResult(this.created, this.alreadyPresent, this.suspended);
  factory GenerateResult.fromJson(Json j) =>
      GenerateResult(j['created'] as int, j['alreadyPresent'] as int, j['suspended'] as int);
  final int created;
  final int alreadyPresent;
  final int suspended;
}

/// Voce scelta per un pagamento: quota esistente o mese da creare.
sealed class PayItem {
  const PayItem();
  Json toJson();
}

class ExistingDueItem extends PayItem {
  const ExistingDueItem(this.dueId);
  final int dueId;
  @override
  Json toJson() => {'dueId': dueId};
}

class NewMonthItem extends PayItem {
  const NewMonthItem(this.year, this.month);
  final int year;
  final int month;
  @override
  Json toJson() => {'year': year, 'month': month};
}
