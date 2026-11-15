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
  AppUser({required this.id, required this.email, required this.name, required this.active, required this.mustChangePassword, this.updatedAt});
  factory AppUser.fromJson(Json j) => AppUser(
        id: j['id'] as int,
        email: j['email'] as String,
        name: j['name'] as String,
        active: j['active'] as bool,
        mustChangePassword: j['mustChangePassword'] as bool,
        updatedAt: j['updatedAt'] as String?,
      );
  final int id;
  final String email;
  final String name;
  final bool active;
  final bool mustChangePassword;
  final String? updatedAt;
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
    this.updatedAt,
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
        updatedAt: j['updatedAt'] as String?,
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

  /// Versione letta, per non sovrascrivere modifiche fatte da altri.
  final String? updatedAt;

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
    this.coursePeriodId,
    this.productId,
    this.variantLabel,
    this.quantity = 1,
    this.buyerName,
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
        coursePeriodId: j['coursePeriodId'] as int?,
        productId: j['productId'] as int?,
        variantLabel: j['variantLabel'] as String?,
        quantity: (j['quantity'] as int?) ?? 1,
        buyerName: j['buyerName'] as String?,
        baseAmountCents: j['baseAmountCents'] as int,
        amountCents: j['amountCents'] as int,
        adjustmentReason: j['adjustmentReason'] as String?,
        paidCents: j['paidCents'] as int,
        remainingCents: j['remainingCents'] as int,
        status: j['status'] as String,
        chargedOn: j['chargedOn'] as String,
      );
  final int id;
  final String kind; // annuale | mensile | periodo | prodotto
  final int year;
  final int? month;
  final String label;
  final int? categoryId;
  final int? coursePeriodId;
  final int? productId;
  final String? variantLabel;
  final int quantity;
  final String? buyerName;
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
    this.memberId,
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
    this.updatedAt,
  });
  factory Payment.fromJson(Json j) => Payment(
        id: j['id'] as int,
        memberId: j['memberId'] as int?,
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
        updatedAt: j['updatedAt'] as String?,
      );
  final int id;
  final int? memberId;
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
  /// Versione da rimandare in If-Match per correggere il pagamento.
  final String? updatedAt;
}

class PaymentMethod {
  PaymentMethod(this.code, this.label, this.active);
  factory PaymentMethod.fromJson(Json j) => PaymentMethod(j['code'] as String, j['label'] as String, j['active'] as bool);
  final String code;
  final String label;
  final bool active;
}

class Fee {
  Fee({required this.categoryId, required this.kind, required this.name, this.months, required this.active, required this.year, this.amountCents, this.updatedAt});
  factory Fee.fromJson(Json j) => Fee(
        categoryId: j['categoryId'] as int,
        kind: j['kind'] as String,
        name: j['name'] as String,
        months: j['months'] as int?,
        active: j['active'] as bool,
        year: j['year'] as int,
        amountCents: j['amountCents'] as int?,
        updatedAt: j['updatedAt'] as String?,
      );
  final int categoryId;
  final String kind; // annuale | mensile | pacchetto
  final String name;
  final int? months;
  final bool active;
  final int year;
  final int? amountCents;

  /// Versione per il controllo delle modifiche: "none" se l'importo non era fissato.
  final String? updatedAt;
  String get version => updatedAt ?? 'none';

  String get title => switch (kind) {
        'annuale' => 'Associativa ${name.toLowerCase()}',
        'mensile' => 'Mensile ${name.toLowerCase()}',
        _ => 'Pacchetto ${name.toLowerCase()}',
      };
}

class ProductVariant {
  ProductVariant({required this.id, required this.size, required this.color, required this.label, required this.active, required this.stock, required this.low});
  factory ProductVariant.fromJson(Json j) => ProductVariant(
        id: j['id'] as int,
        size: j['size'] as String,
        color: j['color'] as String,
        label: j['label'] as String,
        active: j['active'] as bool,
        stock: j['stock'] as int,
        low: j['low'] as bool,
      );
  final int id;
  final String size;
  final String color;
  final String label;
  final bool active;
  final int stock;
  final bool low;
}

class Product {
  Product({
    required this.id,
    required this.name,
    required this.type,
    required this.priceCents,
    required this.active,
    this.tracksStock = false,
    this.lowStockThreshold = 2,
    this.variants = const [],
    this.updatedAt,
  });
  factory Product.fromJson(Json j) => Product(
        id: j['id'] as int,
        name: j['name'] as String,
        type: j['type'] as String,
        priceCents: j['priceCents'] as int,
        active: j['active'] as bool,
        tracksStock: (j['tracksStock'] as bool?) ?? false,
        lowStockThreshold: (j['lowStockThreshold'] as int?) ?? 2,
        variants: [for (final v in (j['variants'] as List?) ?? const []) ProductVariant.fromJson(v as Json)],
        updatedAt: j['updatedAt'] as String?,
      );
  final int id;
  final String name;
  final String type;
  final int priceCents;
  final bool active;
  final bool tracksStock;
  final int lowStockThreshold;
  final List<ProductVariant> variants;
  final String? updatedAt;

  int get totalStock => variants.where((v) => v.active).fold(0, (s, v) => s + v.stock);
  bool get hasLowStock => variants.any((v) => v.low);

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
    this.nonMemberOpenCents = 0,
    this.nonMemberOpenCount = 0,
    required this.members,
  });
  factory StatusReport.fromJson(Json j) => StatusReport(
        activeMembers: j['activeMembers'] as int,
        inRegola: j['inRegola'] as int,
        notInRegola: j['notInRegola'] as int,
        arrearsTotalCents: j['arrearsTotalCents'] as int,
        openChargesTotalCents: j['openChargesTotalCents'] as int,
        nonMemberOpenCents: (j['nonMemberOpenCents'] as int?) ?? 0,
        nonMemberOpenCount: (j['nonMemberOpenCount'] as int?) ?? 0,
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
  final int nonMemberOpenCents;
  final int nonMemberOpenCount;
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
  IncomeReport({
    required this.year,
    required this.totalCents,
    required this.byMonth,
    required this.byMethod,
    required this.byKind,
    this.membersCents = 0,
    this.nonMembersCents = 0,
    this.expensesCents = 0,
    this.expensesByMonth = const [],
    this.expensesByCategory = const [],
    this.toReimburseCents = 0,
    this.toReimburseCount = 0,
    this.noReceiptCount = 0,
    this.balanceCents = 0,
  });
  factory IncomeReport.fromJson(Json j) => IncomeReport(
        year: j['year'] as int,
        totalCents: j['totalCents'] as int,
        byMonth: [for (final v in j['byMonth'] as List) v as int],
        byMethod: [for (final m in j['byMethod'] as List) ((m as Json)['label'] as String, m['cents'] as int)],
        byKind: {for (final e in (j['byKind'] as Json).entries) e.key: e.value as int},
        membersCents: ((j['bySource'] as Json?)?['soci'] as int?) ?? 0,
        nonMembersCents: ((j['bySource'] as Json?)?['nonSoci'] as int?) ?? 0,
        expensesCents: ((j['expenses'] as Json?)?['totalCents'] as int?) ?? 0,
        expensesByMonth: [for (final v in ((j['expenses'] as Json?)?['byMonth'] as List?) ?? const []) v as int],
        expensesByCategory: [
          for (final c in ((j['expenses'] as Json?)?['byCategory'] as List?) ?? const []) ((c as Json)['name'] as String, c['cents'] as int),
        ],
        toReimburseCents: ((j['expenses'] as Json?)?['toReimburseCents'] as int?) ?? 0,
        toReimburseCount: ((j['expenses'] as Json?)?['toReimburseCount'] as int?) ?? 0,
        noReceiptCount: ((j['expenses'] as Json?)?['noReceiptCount'] as int?) ?? 0,
        balanceCents: (j['balanceCents'] as int?) ?? (j['totalCents'] as int),
      );
  final int year;
  final int totalCents;
  final List<int> byMonth;
  final List<(String, int)> byMethod;
  final Map<String, int> byKind;
  final int membersCents;
  final int nonMembersCents;
  final int expensesCents;
  final List<int> expensesByMonth;
  final List<(String, int)> expensesByCategory;
  final int toReimburseCents;
  final int toReimburseCount;
  final int noReceiptCount;
  /// Incassi meno spese dell'anno.
  final int balanceCents;
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

class StockMovement {
  StockMovement({required this.id, required this.variantLabel, required this.kind, required this.quantity, required this.movedOn, this.note, required this.userName, this.soldTo});
  factory StockMovement.fromJson(Json j) => StockMovement(
        id: j['id'] as int,
        variantLabel: j['variantLabel'] as String,
        kind: j['kind'] as String,
        quantity: j['quantity'] as int,
        movedOn: j['movedOn'] as String,
        note: j['note'] as String?,
        userName: j['userName'] as String,
        soldTo: j['soldTo'] as String?,
      );
  final int id;
  final String variantLabel;
  final String kind; // carico | vendita | reso | rettifica
  final int quantity;
  final String movedOn;
  final String? note;
  final String userName;

  /// Per vendite e resi: nome del socio oppure "Non socio".
  final String? soldTo;
}

class StockItem {
  StockItem({required this.productId, required this.productName, required this.variantId, required this.label, required this.stock, required this.low});
  factory StockItem.fromJson(Json j) => StockItem(
        productId: j['productId'] as int,
        productName: j['productName'] as String,
        variantId: j['variantId'] as int,
        label: j['label'] as String,
        stock: j['stock'] as int,
        low: j['low'] as bool,
      );
  final int productId;
  final String productName;
  final int variantId;
  final String label;
  final int stock;
  final bool low;
}

class CoursePeriod {
  CoursePeriod({
    required this.id,
    required this.courseId,
    required this.courseName,
    required this.name,
    required this.label,
    required this.from,
    required this.to,
    required this.months,
    required this.amountCents,
    required this.active,
    required this.enrolled,
    required this.paid,
    this.updatedAt,
  });
  factory CoursePeriod.fromJson(Json j) => CoursePeriod(
        id: j['id'] as int,
        courseId: j['courseId'] as int,
        courseName: j['courseName'] as String,
        name: j['name'] as String,
        label: j['label'] as String,
        from: j['from'] as String,
        to: j['to'] as String,
        months: j['months'] as int,
        amountCents: j['amountCents'] as int,
        active: j['active'] as bool,
        enrolled: j['enrolled'] as int,
        paid: j['paid'] as int,
        updatedAt: j['updatedAt'] as String?,
      );
  final int id;
  final int courseId;
  final String courseName;
  final String name;
  final String label;
  final String from; // AAAA-MM
  final String to;
  final int months;
  final int amountCents;
  final bool active;
  final int enrolled;
  final int paid;
  final String? updatedAt;

  /// Il periodo non è ancora finito (rispetto al mese indicato, AAAA-MM).
  bool notEndedAt(String yearMonth) => to.compareTo(yearMonth) >= 0;
}

class Course {
  Course({required this.id, required this.name, required this.active, required this.periods});
  factory Course.fromJson(Json j) => Course(
        id: j['id'] as int,
        name: j['name'] as String,
        active: j['active'] as bool,
        periods: [for (final p in j['periods'] as List) CoursePeriod.fromJson(p as Json)],
      );
  final int id;
  final String name;
  final bool active;
  final List<CoursePeriod> periods;
}

class Enrollment {
  Enrollment({required this.dueId, required this.memberId, required this.memberName, required this.amountCents, required this.paidCents, this.adjustmentReason});
  factory Enrollment.fromJson(Json j) => Enrollment(
        dueId: j['dueId'] as int,
        memberId: j['memberId'] as int,
        memberName: j['memberName'] as String,
        amountCents: j['amountCents'] as int,
        paidCents: j['paidCents'] as int,
        adjustmentReason: j['adjustmentReason'] as String?,
      );
  final int dueId;
  final int memberId;
  final String memberName;
  final int amountCents;
  final int paidCents;
  final String? adjustmentReason;
}

/// Dove è usato un dato e se si può eliminare (vedi /usage/{kind}/{id}).
class Usage {
  Usage({required this.name, required this.deletable, required this.uses, required this.message, this.hint});
  factory Usage.fromJson(Json j) => Usage(
        name: j['name'] as String,
        deletable: j['deletable'] as bool,
        uses: [for (final u in j['uses'] as List) UsageItem.fromJson(u as Json)],
        message: j['message'] as String,
        hint: j['hint'] as String?,
      );
  final String name;
  final bool deletable;
  final List<UsageItem> uses;
  final String message;
  final String? hint;
}

class UsageItem {
  UsageItem({required this.what, required this.count, required this.blocking, required this.examples});
  factory UsageItem.fromJson(Json j) => UsageItem(
        what: j['what'] as String,
        count: j['count'] as int,
        blocking: j['blocking'] as bool,
        examples: [for (final e in j['examples'] as List) e as String],
      );
  final String what;
  final int count;
  final bool blocking;
  final List<String> examples;
}

/// Spesa dell'associazione: pagata dalla cassa o anticipata da qualcuno da rimborsare.
class Expense {
  Expense({
    required this.id,
    required this.spentOn,
    required this.description,
    required this.amountCents,
    required this.categoryId,
    required this.categoryName,
    this.methodCode,
    this.methodLabel,
    this.advancedBy,
    this.reimbursedOn,
    required this.toReimburse,
    required this.hasReceipt,
    this.note,
    required this.createdBy,
    required this.updatedAt,
  });
  factory Expense.fromJson(Json j) => Expense(
        id: j['id'] as int,
        spentOn: j['spentOn'] as String,
        description: j['description'] as String,
        amountCents: j['amountCents'] as int,
        categoryId: (j['category'] as Json)['id'] as int,
        categoryName: (j['category'] as Json)['name'] as String,
        methodCode: (j['method'] as Json?)?['code'] as String?,
        methodLabel: (j['method'] as Json?)?['label'] as String?,
        advancedBy: j['advancedBy'] as String?,
        reimbursedOn: j['reimbursedOn'] as String?,
        toReimburse: j['toReimburse'] as bool,
        hasReceipt: j['hasReceipt'] as bool,
        note: j['note'] as String?,
        createdBy: j['createdBy'] as String,
        updatedAt: j['updatedAt'] as String,
      );
  final int id;
  final String spentOn;
  final String description;
  final int amountCents;
  final int categoryId;
  final String categoryName;
  final String? methodCode;
  final String? methodLabel;
  final String? advancedBy;
  final String? reimbursedOn;
  final bool toReimburse;
  final bool hasReceipt;
  final String? note;
  final String createdBy;
  final String updatedAt;
}

class ExpenseList {
  ExpenseList({required this.items, required this.totalCents, required this.toReimburseCents, required this.toReimburseCount});
  factory ExpenseList.fromJson(Json j) => ExpenseList(
        items: [for (final e in j['items'] as List) Expense.fromJson(e as Json)],
        totalCents: j['totalCents'] as int,
        toReimburseCents: j['toReimburseCents'] as int,
        toReimburseCount: j['toReimburseCount'] as int,
      );
  final List<Expense> items;
  final int totalCents;
  final int toReimburseCents;
  final int toReimburseCount;
}

class ExpenseCategory {
  ExpenseCategory(this.id, this.name, this.active);
  factory ExpenseCategory.fromJson(Json j) => ExpenseCategory(j['id'] as int, j['name'] as String, j['active'] as bool);
  final int id;
  final String name;
  final bool active;
}

/// Livello dell'API del server e pagina da cui scaricare l'app aggiornata.
class VersionInfo {
  VersionInfo({required this.apiLevel, this.appDownloadUrl});
  factory VersionInfo.fromJson(Json j) => VersionInfo(apiLevel: j['apiLevel'] as int, appDownloadUrl: j['appDownloadUrl'] as String?);
  final int apiLevel;
  final String? appDownloadUrl;
}
