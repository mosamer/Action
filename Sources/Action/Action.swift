import Foundation
import RxSwift
import RxCocoa

/// Typealias for compatibility with UIButton's rx.action property.
public typealias CocoaAction = Action<Void, Void>
/// Typealias for actions with work factory returns `Completable`.
public typealias CompletableAction<Input> = Action<Input, Never>

/// Possible errors from invoking execute()
public enum ActionError: Error {
    case notEnabled
    case underlyingError(Error)
}

/**
Represents a value that accepts a workFactory which takes some Observable<Input> as its input
and produces an Observable<Element> as its output.

When this excuted via execute() or inputs subject, it passes its parameter to this closure and subscribes to the work.
*/
public final class Action<Input, Element> {
    public typealias WorkFactory = (Input) -> Observable<Element>


    /// Bindable sink for inputs that triggers execution of action.
    public let inputs: AnyObserver<Input>

    /// Errors aggrevated from invocations of execute().
    /// Delivered on whatever scheduler they were sent from.
    public let errors: Observable<ActionError>

    /// Whether or not we're currently executing.
    /// Delivered on whatever scheduler they were sent from.
    public let elements: Observable<Element>

    /// Whether or not we're currently executing. 
    public let isExecuting: Observable<Bool>

    /// Observables returned by the workFactory.
    /// Useful for sending results back from work being completed
    /// e.g. response from a network call.
    public let executionObservables: Observable<Observable<Element>>

    /// Whether or not we're enabled. Note that this is a *computed* sequence
    /// property based on enabledIf initializer and if we're currently executing.
    /// Always observed on MainScheduler.
    public let isEnabled: Observable<Bool>

    private let disposeBag = DisposeBag()

    public convenience init<O: ObservableConvertibleType>(
        enabledIf: Observable<Bool> = Observable.just(true),
        workFactory: @escaping (Input) -> O
    ) where O.E == Element {
        self.init(enabledIf: enabledIf) {
            workFactory($0).asObservable()
        }
    }

    public init(
        enabledIf: Observable<Bool> = Observable.just(true),
        workFactory: @escaping WorkFactory) {

        let enabledSubject = BehaviorSubject<Bool>(value: false)
        isEnabled = enabledSubject.asObservable()

        let errorsSubject = PublishSubject<ActionError>()
        errors = errorsSubject.asObservable()

        let inputsSubject = InputSubject<Input>()
        inputs = inputsSubject.asObserver()

        executionObservables = inputsSubject
            .withLatestFrom(isEnabled) { input, enabled in (input, enabled) }
            .flatMap { input, enabled -> Observable<Observable<Element>> in
                if enabled {
                    return Observable.of(workFactory(input)
                                             .do(onError: { errorsSubject.onNext(.underlyingError($0)) })
                                             .share(replay: 1, scope: .forever))
                } else {
                    errorsSubject.onNext(.notEnabled)
                    return Observable.empty()
                }
            }
            .share()

        elements = executionObservables
            .flatMap { $0.catchError { _ in Observable.empty() } }

        isExecuting = executionObservables.flatMap {
                execution -> Observable<Bool> in
                let execution = execution
                    .flatMap { _ in Observable<Bool>.empty() }
                    .catchError { _ in Observable.empty() }

                return Observable.concat([Observable.just(true),
                                          execution,
                                          Observable.just(false)])
            }
            .startWith(false)
            .share(replay: 1, scope: .forever)

        Observable
            .combineLatest(isExecuting, enabledIf) { !$0 && $1 }
            .bind(to: enabledSubject)
            .disposed(by: disposeBag)
    }

    @discardableResult
    public func execute(_ value: Input) -> Observable<Element> {
        defer {
            inputs.onNext(value)
        }

		let subject = ReplaySubject<Element>.createUnbounded()

		let work = executionObservables
			.map { $0.catchError { throw ActionError.underlyingError($0) } }

		let error = errors
			.map { Observable<Element>.error($0) }

		work.amb(error)
			.take(1)
			.flatMap { $0 }
			.subscribe(subject)
			.disposed(by: disposeBag)

		return subject.asObservable()
    }
}

// MARK: Deprecated
extension Action {
    @available(*, deprecated, renamed: "isExecuting")
    public var executing: Observable<Bool> {
        return isExecuting
    }

    @available(*, deprecated, renamed: "isEnabled")
    public var enabled: Observable<Bool> {
        return isEnabled
    }
}
